package app

import (
	"encoding/json"
	"net/http/httptest"
	"os"
	"strconv"
	"strings"
	"testing"

	"golang.org/x/crypto/bcrypt"
)

func TestMySQLUserEditing(t *testing.T) {
	dsn := os.Getenv("TEST_MYSQL_DSN")
	if dsn == "" {
		t.Skip("set TEST_MYSQL_DSN to a disposable MySQL database")
	}
	a, err := Open(dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(a.Close)
	makeUser := func(username, role string, active bool) User {
		r, e := a.db.Exec("INSERT INTO users(name,username,password_hash,role,active) VALUES(?,?,'unused',?,?)", username, username, role, active)
		if e != nil {
			t.Fatal(e)
		}
		id, _ := r.LastInsertId()
		t.Cleanup(func() {
			a.db.Exec("DELETE FROM audit_events WHERE user_id=? OR resource_id=?", id, id)
			a.db.Exec("DELETE FROM sessions WHERE user_id=?", id)
			a.db.Exec("DELETE FROM users WHERE id=?", id)
		})
		return User{ID: id, Name: username, Username: username, Role: role, Active: active}
	}
	admin := makeUser("edit-admin", "admin", true)
	target := makeUser("edit-teacher", "teacher", false)
	other := makeUser("edit-other", "student", true)
	patch := func(actor User, id int64, body string, want int) {
		t.Helper()
		r := httptest.NewRequest("PATCH", "/api/v1/admin/users/"+strconv.FormatInt(id, 10), strings.NewReader(body))
		_, e := a.route(r, actor, "")
		got := 200
		if e != nil {
			v, ok := e.(*apiError)
			if !ok {
				t.Fatal(e)
			}
			got = v.Code
		}
		if got != want {
			t.Fatalf("PATCH %s: got %d, want %d (%v)", body, got, want, e)
		}
	}
	read := func(id int64) User {
		t.Helper()
		var u User
		if e := a.db.QueryRow("SELECT id,name,username,role,active FROM users WHERE id=?", id).Scan(&u.ID, &u.Name, &u.Username, &u.Role, &u.Active); e != nil {
			t.Fatal(e)
		}
		return u
	}
	patch(other, target.ID, `{"name":"No autorizado"}`, 403)
	patch(User{ID: target.ID, Role: "teacher"}, target.ID, `{"name":"No autorizado"}`, 403)
	patch(admin, target.ID, `{"name":" Docente corregido ","username":" EDIT-RENAMED "}`, 200)
	u := read(target.ID)
	if u.Name != "Docente corregido" || u.Username != "edit-renamed" || u.Active || u.Role != "teacher" {
		t.Fatalf("unexpected user: %+v", u)
	}
	patch(admin, target.ID, `{"name":"No guardar","username":"edit-other","active":true}`, 409)
	u = read(target.ID)
	if u.Name != "Docente corregido" || u.Active {
		t.Fatal("conflicting edit was partially saved")
	}
	patch(admin, target.ID, `{"name":" "}`, 400)
	patch(admin, target.ID, `{"username":"ab"}`, 400)
	patch(admin, target.ID, `{"password":"short"}`, 400)
	patch(admin, target.ID, `{}`, 400)
	patch(admin, 99999999, `{"name":"Missing"}`, 404)
	patch(admin, admin.ID, `{"active":false}`, 400)
	patch(admin, admin.ID, `{"password":"new-admin-password"}`, 400)
	if _, err = a.db.Exec("INSERT INTO sessions(token_hash,user_id,expires_at) VALUES('edit-session',?,DATE_ADD(UTC_TIMESTAMP(),INTERVAL 1 HOUR))", admin.ID); err != nil {
		t.Fatal(err)
	}
	patch(admin, admin.ID, `{"name":"Administrador corregido","username":"edit-admin-new"}`, 200)
	var n int
	a.db.QueryRow("SELECT COUNT(*) FROM sessions WHERE user_id=?", admin.ID).Scan(&n)
	if n != 1 {
		t.Fatal("self profile edit revoked current session")
	}
	if _, err = a.db.Exec("INSERT INTO sessions(token_hash,user_id,expires_at) VALUES('edit-target-session',?,DATE_ADD(UTC_TIMESTAMP(),INTERVAL 1 HOUR))", target.ID); err != nil {
		t.Fatal(err)
	}
	patch(admin, target.ID, `{"active":true,"password":"replacement-password"}`, 200)
	var hash string
	a.db.QueryRow("SELECT password_hash FROM users WHERE id=?", target.ID).Scan(&hash)
	if bcrypt.CompareHashAndPassword([]byte(hash), []byte("replacement-password")) != nil {
		t.Fatal("password not updated")
	}
	a.db.QueryRow("SELECT COUNT(*) FROM sessions WHERE user_id=?", target.ID).Scan(&n)
	if n != 0 || !read(target.ID).Active {
		t.Fatal("access change did not revoke sessions or activate user")
	}
	var detail string
	if err = a.db.QueryRow("SELECT detail FROM audit_events WHERE action='user.update' AND resource_id=? ORDER BY id DESC LIMIT 1", target.ID).Scan(&detail); err != nil {
		t.Fatal(err)
	}
	var event map[string]any
	if err = json.Unmarshal([]byte(detail), &event); err != nil {
		t.Fatal(err)
	}
	if event["password_reset"] != true || strings.Contains(detail, "replacement-password") {
		t.Fatal("invalid audit payload")
	}
}
