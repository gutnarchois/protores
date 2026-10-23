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

func TestAttendanceAccessAndValidation(t *testing.T) {
	a := &App{}
	for _, v := range []struct {
		role, path, body string
		code             int
	}{
		{"student", "/students", "", 403}, {"student", "/attendance", `{"code":"x"}`, 403},
		{"teacher", "/students", `{"name":"x"}`, 403}, {"admin", "/students", `{"name":" "}`, 400},
		{"teacher", "/attendance", `{"code":" "}`, 400}, {"admin", "/attendance", `{"code":1}`, 400},
	} {
		r := httptest.NewRequest("POST", "/api/v1"+v.path, strings.NewReader(v.body))
		_, err := a.route(r, User{Role: v.role}, "")
		e, ok := err.(*apiError)
		if !ok || e.Code != v.code {
			t.Fatalf("%+v: %v", v, err)
		}
	}
}

func TestMySQLAttendance(t *testing.T) {
	dsn := os.Getenv("TEST_MYSQL_DSN")
	if dsn == "" {
		t.Skip("set TEST_MYSQL_DSN to a disposable MySQL database")
	}
	a, err := Open(dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer a.Close()
	res, err := a.db.Exec("INSERT INTO users(name,username,password_hash,role) VALUES('Attendance teacher','attendance-test','unused','teacher')")
	if err != nil {
		t.Fatal(err)
	}
	uid, _ := res.LastInsertId()
	defer a.db.Exec("DELETE FROM users WHERE id=?", uid)
	res, err = a.db.Exec("INSERT INTO school_groups(name,teacher_id) VALUES('Attendance test',?)", uid)
	if err != nil {
		t.Fatal(err)
	}
	gid, _ := res.LastInsertId()
	defer a.db.Exec("DELETE FROM school_groups WHERE id=?", gid)
	call := func(role string, id int64, method, path, body string) (any, error) {
		return a.route(httptest.NewRequest(method, "/api/v1"+path, strings.NewReader(body)), User{ID: id, Role: role}, "")
	}
	body := fmt.Sprintf(`{"name":"María","code":"ATT-TEST","group_id":%d}`, gid)
	if _, err = call("admin", uid, "POST", "/students", body); err != nil {
		t.Fatal(err)
	}
	defer a.db.Exec("DELETE FROM students WHERE code='ATT-TEST'")
	if _, err = call("admin", uid, "POST", "/students", body); err == nil {
		t.Fatal("duplicate code accepted")
	}
	d := Day{Date: today(), Status: "running", Turns: []Turn{{ID: 1, GroupID: gid, Status: "active"}}}
	raw, _ := json.Marshal(d)
	_, err = a.db.Exec("INSERT INTO service_days(service_date,state) VALUES(?,?)", today(), raw)
	if err != nil {
		t.Fatal(err)
	}
	defer a.db.Exec("DELETE FROM service_days WHERE service_date=?", today())
	defer a.db.Exec("DELETE FROM attendance WHERE registered_by=?", uid)
	if _, err = call("teacher", uid+999, "POST", "/attendance", `{"code":"ATT-TEST"}`); err == nil {
		t.Fatal("other teacher registered student")
	}
	d.Status = "paused"
	raw, _ = json.Marshal(d)
	a.db.Exec("UPDATE service_days SET state=? WHERE service_date=?", raw, today())
	if _, err = call("teacher", uid, "POST", "/attendance", `{"code":"ATT-TEST"}`); err == nil {
		t.Fatal("registration accepted while paused")
	}
	d.Status = "running"
	raw, _ = json.Marshal(d)
	a.db.Exec("UPDATE service_days SET state=? WHERE service_date=?", raw, today())
	var wg sync.WaitGroup
	results := make(chan error, 8)
	for range 8 {
		wg.Go(func() { _, e := call("teacher", uid, "POST", "/attendance", `{"code":"ATT-TEST"}`); results <- e })
	}
	wg.Wait()
	close(results)
	success := 0
	for e := range results {
		if e == nil {
			success++
		} else if v, ok := e.(*apiError); !ok || v.Code != 409 {
			t.Fatal(e)
		}
	}
	if success != 1 {
		t.Fatalf("%d duplicate registrations accepted", success)
	}
	got, err := call("teacher", uid, "GET", "/students", "")
	if err != nil {
		t.Fatal(err)
	}
	roster := got.([]map[string]any)
	if len(roster) != 1 || roster[0]["registered_at"] == nil {
		t.Fatalf("unexpected roster: %+v", roster)
	}
	got, err = call("teacher", uid+999, "GET", "/students", "")
	if err != nil || len(got.([]map[string]any)) != 0 {
		t.Fatalf("roster leaked: %v %v", got, err)
	}
}
