package app

import (
	"encoding/json"
	"fmt"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"testing"
)

func TestScheduleValidation(t *testing.T) {
	cases := []struct {
		name  string
		turns []scheduleTurn
		valid bool
	}{
		{"individual durations", []scheduleTurn{{GroupID: 1, Start: "07:00", Minutes: 20}, {GroupID: 2, Start: "07:25", Minutes: 40}}, true},
		{"overlap", []scheduleTurn{{GroupID: 1, Start: "07:00", Minutes: 30}, {GroupID: 2, Start: "07:15", Minutes: 30}}, false},
		{"duplicate group", []scheduleTurn{{GroupID: 1, Start: "07:00", Minutes: 30}, {GroupID: 1, Start: "07:30", Minutes: 30}}, false},
		{"duplicate ID", []scheduleTurn{{ID: 1, GroupID: 1, Start: "07:00", Minutes: 30}, {ID: 1, GroupID: 2, Start: "07:30", Minutes: 30}}, false},
		{"cross midnight", []scheduleTurn{{GroupID: 1, Start: "23:50", Minutes: 30}}, false},
		{"bad time", []scheduleTurn{{GroupID: 1, Start: "25:00", Minutes: 30}}, false},
		{"zero duration", []scheduleTurn{{GroupID: 1, Start: "07:00", Minutes: 0}}, false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			_, err := validateSchedule(today(), c.turns)
			if (err == nil) != c.valid {
				t.Fatalf("valid=%v error=%v", c.valid, err)
			}
		})
	}
	a := &App{}
	for _, role := range []string{"student", "teacher"} {
		_, err := a.route(httptest.NewRequest("PATCH", "/api/v1/admin/service-days/1", strings.NewReader(`{}`)), User{Role: role}, "")
		if e, ok := err.(*apiError); !ok || e.Code != 403 {
			t.Fatalf("%s: %v", role, err)
		}
	}
}

func TestMySQLScheduleEditing(t *testing.T) {
	dsn := os.Getenv("TEST_MYSQL_DSN")
	if dsn == "" {
		t.Skip("set TEST_MYSQL_DSN to a disposable MySQL database")
	}
	a, err := Open(dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer a.Close()
	res, err := a.db.Exec("INSERT INTO users(name,username,password_hash,role) VALUES('Schedule teacher','schedule-test','unused','teacher')")
	if err != nil {
		t.Fatal(err)
	}
	uid, _ := res.LastInsertId()
	defer a.db.Exec("DELETE FROM users WHERE id=?", uid)
	gids := []int64{}
	defer func() {
		for _, id := range gids {
			a.db.Exec("DELETE FROM school_groups WHERE id=?", id)
		}
	}()
	for i := range 3 {
		r, e := a.db.Exec("INSERT INTO school_groups(name,teacher_id) VALUES(?,?)", fmt.Sprintf("Schedule test %d", i), uid)
		if e != nil {
			t.Fatal(e)
		}
		id, _ := r.LastInsertId()
		gids = append(gids, id)
	}
	actor := User{ID: uid, Role: "admin"}
	inputs := []scheduleTurn{{GroupID: gids[0], Start: "07:00", Minutes: 20}, {GroupID: gids[1], Start: "07:30", Minutes: 40}}
	raw, _ := json.Marshal(map[string]any{"date": today(), "turns": inputs})
	value, err := a.route(httptest.NewRequest("POST", "/api/v1/admin/service-days", strings.NewReader(string(raw))), actor, "")
	if err != nil {
		t.Fatal(err)
	}
	d := value.(Day)
	defer a.db.Exec("DELETE FROM service_days WHERE id=?", d.ID)
	defer a.db.Exec("DELETE FROM audit_events WHERE user_id=?", uid)
	patch := func(version int64, turns []scheduleTurn) (any, error) {
		body, _ := json.Marshal(map[string]any{"date": today(), "version": version, "turns": turns})
		return a.route(httptest.NewRequest("PATCH", fmt.Sprintf("/api/v1/admin/service-days/%d", d.ID), strings.NewReader(string(body))), actor, "")
	}
	inputs[0].ID = d.Turns[0].ID
	inputs[1].ID = d.Turns[1].ID
	inputs[0].Minutes = 25
	inputs[1].Start = "08:00"
	value, err = patch(d.Version, inputs)
	if err != nil {
		t.Fatal(err)
	}
	d = value.(Day)
	if d.Version != 2 || d.Turns[0].Duration != 1500 {
		t.Fatalf("edit not persisted: %+v", d)
	}
	if _, err = patch(1, inputs); err == nil {
		t.Fatal("stale edit accepted")
	}
	// Concurrent editors must not overwrite each other's changes.
	var wg sync.WaitGroup
	results := make(chan error, 2)
	for range 2 {
		wg.Go(func() { _, e := patch(2, inputs); results <- e })
	}
	wg.Wait()
	close(results)
	success := 0
	for e := range results {
		if e == nil {
			success++
		} else if x, ok := e.(*apiError); !ok || x.Code != 409 {
			t.Fatal(e)
		}
	}
	if success != 1 {
		t.Fatalf("%d concurrent edits accepted", success)
	}
	d, err = a.loadDay(t.Context(), today())
	if err != nil {
		t.Fatal(err)
	}
	d.Status = "running"
	d.Turns[0].Status = "active"
	raw, _ = json.Marshal(d)
	if _, err = a.db.Exec("UPDATE service_days SET state=? WHERE id=?", raw, d.ID); err != nil {
		t.Fatal(err)
	}
	protected := append([]scheduleTurn(nil), inputs...)
	protected[0].Minutes = 30
	if _, err = patch(d.Version, protected); err == nil {
		t.Fatal("active turn duration changed")
	}
	if _, err = patch(d.Version, inputs[1:]); err == nil {
		t.Fatal("active turn removed")
	}
	inputs[1].Minutes = 35
	inputs = append(inputs, scheduleTurn{GroupID: gids[2], Start: "09:00", Minutes: 15})
	value, err = patch(d.Version, inputs)
	if err != nil {
		t.Fatal(err)
	}
	updated := value.(Day)
	if updated.Turns[0].Status != "active" || updated.Turns[0].ID != d.Turns[0].ID || len(updated.Turns) != 3 {
		t.Fatalf("lost active state: %+v", updated)
	}
	// Unknown and unavailable groups cannot cause partial updates.
	inputs[1].GroupID = 9999999
	if _, err = patch(updated.Version, inputs); err == nil {
		t.Fatal("unknown group accepted")
	}
	current, _ := a.loadDay(t.Context(), today())
	if current.Version != updated.Version {
		t.Fatal("failed edit changed version")
	}
}
