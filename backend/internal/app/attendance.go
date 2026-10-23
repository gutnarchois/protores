package app

import (
	"database/sql"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/go-sql-driver/mysql"
)

// Attendance is restricted to administrators and the group's assigned teacher.
func (a *App) attendance(r *http.Request, u User, path string) (any, error) {
	if u.Role != "admin" && u.Role != "teacher" {
		return nil, fail(403, "Solo personal autorizado")
	}
	ctx := r.Context()
	date := today()
	if path == "/students" && r.Method == "POST" {
		if u.Role != "admin" {
			return nil, fail(403, "Solo administradores")
		}
		var p struct {
			Name    string `json:"name"`
			Code    string `json:"code"`
			GroupID int64  `json:"group_id"`
		}
		if e := decode(r, &p); e != nil {
			return nil, e
		}
		p.Name = strings.TrimSpace(p.Name)
		p.Code = strings.TrimSpace(p.Code)
		if p.Name == "" || len(p.Name) > 120 || p.Code == "" || len(p.Code) > 80 || p.GroupID < 1 {
			return nil, fail(400, "Nombre, código y curso válidos son obligatorios")
		}
		res, e := a.db.ExecContext(ctx, "INSERT INTO students(name,code,group_id) SELECT ?,?,id FROM school_groups WHERE id=? AND active=TRUE", p.Name, p.Code, p.GroupID)
		var me *mysql.MySQLError
		if errors.As(e, &me) && me.Number == 1062 {
			return nil, fail(409, "El código ya está registrado")
		}
		if e != nil {
			return nil, e
		}
		n, _ := res.RowsAffected()
		if n == 0 {
			return nil, fail(400, "Curso no disponible")
		}
		return map[string]bool{"ok": true}, nil
	}
	if path == "/students" && r.Method == "GET" {
		rows, e := a.db.QueryContext(ctx, `SELECT s.id,s.name,s.code,s.group_id,g.name,a.registered_at FROM students s JOIN school_groups g ON g.id=s.group_id LEFT JOIN attendance a ON a.student_id=s.id AND a.service_date=? WHERE g.active=TRUE AND (?='admin' OR g.teacher_id=?) ORDER BY s.name`, date, u.Role, u.ID)
		if e != nil {
			return nil, e
		}
		defer rows.Close()
		items := []map[string]any{}
		for rows.Next() {
			var id, gid int64
			var name, code, group string
			var at sql.NullTime
			if e = rows.Scan(&id, &name, &code, &gid, &group, &at); e != nil {
				return nil, e
			}
			v := map[string]any{"id": id, "name": name, "code": code, "group_id": gid, "group_name": group, "registered_at": nil}
			if at.Valid {
				v["registered_at"] = at.Time.UTC().Format(time.RFC3339)
			}
			items = append(items, v)
		}
		return items, rows.Err()
	}
	if path == "/attendance" && r.Method == "POST" {
		var p struct {
			Code string `json:"code"`
		}
		if e := decode(r, &p); e != nil {
			return nil, e
		}
		p.Code = strings.TrimSpace(p.Code)
		if p.Code == "" || len(p.Code) > 80 {
			return nil, fail(400, "Código inválido")
		}
		tx, e := a.db.BeginTx(ctx, nil)
		if e != nil {
			return nil, e
		}
		defer tx.Rollback()
		var state string
		e = tx.QueryRowContext(ctx, "SELECT state FROM service_days WHERE service_date=? FOR UPDATE", date).Scan(&state)
		if errors.Is(e, sql.ErrNoRows) {
			return nil, fail(409, "No hay jornada programada")
		}
		if e != nil {
			return nil, e
		}
		var d Day
		if e = json.Unmarshal([]byte(state), &d); e != nil {
			return nil, e
		}
		var sid, gid, teacher int64
		var name string
		e = tx.QueryRowContext(ctx, "SELECT s.id,s.name,s.group_id,g.teacher_id FROM students s JOIN school_groups g ON g.id=s.group_id WHERE s.code=? AND g.active=TRUE", p.Code).Scan(&sid, &name, &gid, &teacher)
		if errors.Is(e, sql.ErrNoRows) {
			return nil, fail(404, "Estudiante no encontrado")
		}
		if e != nil {
			return nil, e
		}
		if u.Role != "admin" && teacher != u.ID {
			return nil, fail(403, "El estudiante pertenece a otro docente")
		}
		allowed := false
		for _, t := range d.Turns {
			if t.GroupID == gid && t.Status == "active" {
				allowed = true
			}
		}
		if d.Status != "running" || !allowed {
			return nil, fail(409, "El curso no está en atención")
		}
		_, e = tx.ExecContext(ctx, "INSERT INTO attendance(student_id,service_date,registered_by) VALUES(?,?,?)", sid, date, u.ID)
		var me *mysql.MySQLError
		if errors.As(e, &me) && me.Number == 1062 {
			return nil, fail(409, "El estudiante ya ingresó hoy")
		}
		if e != nil {
			return nil, e
		}
		if e = tx.Commit(); e != nil {
			return nil, e
		}
		return map[string]any{"ok": true, "name": name}, nil
	}
	return nil, fail(405, "Método no permitido")
}
