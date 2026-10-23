package app

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"testing"
	"time"
)

func sample() Day {
	return Day{Status: "scheduled", Turns: []Turn{{ID: 1, TeacherID: 10, Status: "pending", Duration: 600}, {ID: 2, TeacherID: 11, Status: "pending", Duration: 600}}}
}
func TestTurnLifecycle(t *testing.T) {
	d := sample()
	now := time.Now().UTC()
	admin := User{ID: 1, Role: "admin"}
	teacher := User{ID: 10, Role: "teacher"}
	if e := transition(&d, admin, "start", 1, "", now); e != nil {
		t.Fatal(e)
	}
	if e := transition(&d, User{ID: 11, Role: "teacher"}, "finish", 1, "", now); e == nil {
		t.Fatal("another teacher finished turn")
	}
	if e := transition(&d, User{ID: 10, Role: "student"}, "finish", 1, "", now); e == nil {
		t.Fatal("student finished turn")
	}
	if e := transition(&d, admin, "pause", 1, "", now); e != nil {
		t.Fatal(e)
	}
	if e := transition(&d, teacher, "finish", 1, "", now); e == nil {
		t.Fatal("finished while paused")
	}
	if e := transition(&d, admin, "resume", 1, "", now.Add(time.Minute)); e != nil {
		t.Fatal(e)
	}
	if d.Turns[0].PausedSeconds != 60 {
		t.Fatal("pause duration")
	}
	if e := transition(&d, teacher, "finish", 1, "", now.Add(2*time.Minute)); e != nil {
		t.Fatal(e)
	}
	if d.Turns[1].Status != "active" || d.Turns[0].Status != "finished" {
		t.Fatal("next turn did not activate")
	}
	if e := transition(&d, admin, "skip", 2, "", now); e == nil {
		t.Fatal("skip without reason")
	}
	if e := transition(&d, admin, "skip", 2, "Ausente", now); e != nil {
		t.Fatal(e)
	}
	if d.Status != "finished" {
		t.Fatal("day did not finish")
	}
}
func TestPendingCancellationDoesNotAdvanceActive(t *testing.T) {
	d := sample()
	admin := User{Role: "admin"}
	now := time.Now()
	_ = transition(&d, admin, "start", 1, "", now)
	if e := transition(&d, admin, "cancel", 2, "Ausente", now); e != nil {
		t.Fatal(e)
	}
	if d.Turns[0].Status != "active" || d.Status != "running" {
		t.Fatal("cancelled pending advanced current")
	}
}
func TestMySQLConcurrentFinish(t *testing.T) {
	dsn := os.Getenv("TEST_MYSQL_DSN")
	if dsn == "" {
		t.Skip("set TEST_MYSQL_DSN to a disposable MySQL database")
	}
	a, e := Open(dsn)
	if e != nil {
		t.Fatal(e)
	}
	defer a.Close()
	// This test uses a separate disposable database; do not point at production.
	_, e = a.db.Exec("INSERT INTO users(name,username,password_hash,role) VALUES('Test','concurrent-test','unused','teacher') ON DUPLICATE KEY UPDATE active=1")
	if e != nil {
		t.Fatal(e)
	}
	var uid int64
	_ = a.db.QueryRow("SELECT id FROM users WHERE username='concurrent-test'").Scan(&uid)
	d := sample()
	d.Date = today()
	d.Status = "running"
	d.Version = 1
	d.Turns[0].Status = "active"
	d.Turns[0].TeacherID = uid
	now := time.Now().UTC()
	d.Turns[0].StartedAt = &now
	_, _ = a.db.Exec("DELETE FROM service_days WHERE service_date=?", today())
	raw := mustJSON(t, d)
	res, e := a.db.Exec("INSERT INTO service_days(service_date,state) VALUES(?,?)", today(), raw)
	if e != nil {
		t.Fatal(e)
	}
	id, _ := res.LastInsertId()
	defer a.db.Exec("DELETE FROM service_days WHERE id=?", id)
	var wg sync.WaitGroup
	errs := make(chan error, 12)
	for range 12 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			r := httptest.NewRequest("POST", "/", strings.NewReader(`{"date":"`+today()+`","version":1}`))
			_, e := a.change(r, User{ID: uid, Role: "teacher"}, "finish", 1)
			errs <- e
		}()
	}
	wg.Wait()
	close(errs)
	for e := range errs {
		if e != nil {
			t.Fatal(e)
		}
	}
	got, e := a.loadDay(t.Context(), today())
	if e != nil {
		t.Fatal(e)
	}
	if got.Version != 2 || got.Turns[1].Status != "active" {
		t.Fatalf("duplicate advance: %+v", got)
	}
	var n int
	_ = a.db.QueryRow("SELECT COUNT(*) FROM audit_events WHERE resource_id=? AND action='finish'", id).Scan(&n)
	if n != 1 {
		t.Fatalf("expected one audit event, got %d", n)
	}
	r := httptest.NewRequest(http.MethodGet, "/api/v1/status", nil)
	w := httptest.NewRecorder()
	a.Handler().ServeHTTP(w, r)
	if w.Code != 401 {
		t.Fatal("unauthenticated request accepted")
	}
}

func mustJSON(t *testing.T, v any) []byte {
	t.Helper()
	b, e := json.Marshal(v)
	if e != nil {
		t.Fatal(e)
	}
	return b
}
