package app

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	_ "embed"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"
	_ "time/tzdata"

	"github.com/go-sql-driver/mysql"
	"golang.org/x/crypto/bcrypt"
)

//go:embed schema.sql
var schema string

type App struct {
	db       *sql.DB
	loginMu  sync.Mutex
	attempts map[string]attempt
}
type attempt struct {
	Count int
	Until time.Time
}
type User struct {
	ID       int64  `json:"id"`
	Name     string `json:"name"`
	Username string `json:"username"`
	Role     string `json:"role"`
	Active   bool   `json:"active"`
}
type Group struct {
	ID        int64  `json:"id"`
	Name      string `json:"name"`
	TeacherID int64  `json:"teacher_id"`
	Active    bool   `json:"active"`
}
type Turn struct {
	ID            int64      `json:"id"`
	GroupID       int64      `json:"group_id"`
	GroupName     string     `json:"group_name"`
	TeacherID     int64      `json:"teacher_id"`
	Scheduled     string     `json:"scheduled"`
	Duration      int        `json:"duration_seconds"`
	Status        string     `json:"status"`
	StartedAt     *time.Time `json:"started_at,omitempty"`
	FinishedAt    *time.Time `json:"finished_at,omitempty"`
	PausedSeconds float64    `json:"paused_seconds"`
}
type Day struct {
	ID       int64      `json:"id"`
	Date     string     `json:"date"`
	Status   string     `json:"status"`
	Version  int64      `json:"version"`
	PausedAt *time.Time `json:"paused_at,omitempty"`
	Turns    []Turn     `json:"turns"`
}
type apiError struct {
	Code    int
	Message string
}

func (e *apiError) Error() string     { return e.Message }
func fail(code int, msg string) error { return &apiError{code, msg} }
func Open(dsn string) (*App, error) {
	if dsn == "" {
		return nil, errors.New("MYSQL_DSN es obligatorio")
	}
	cfg, err := mysql.ParseDSN(dsn)
	if err != nil {
		return nil, errors.New("MYSQL_DSN inválido")
	}
	cfg.ParseTime = true
	cfg.Loc = time.UTC
	cfg.MultiStatements = false
	cfg.Timeout = 5 * time.Second
	cfg.ReadTimeout = 10 * time.Second
	cfg.WriteTimeout = 10 * time.Second
	db, err := sql.Open("mysql", cfg.FormatDSN())
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(8)
	db.SetMaxIdleConns(3)
	db.SetConnMaxLifetime(3 * time.Minute)
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	if err = db.PingContext(ctx); err != nil {
		db.Close()
		return nil, errors.New("No se pudo conectar a MySQL")
	}
	for _, stmt := range strings.Split(schema, ";") {
		if strings.TrimSpace(stmt) != "" {
			if _, err = db.ExecContext(ctx, stmt); err != nil {
				db.Close()
				return nil, fmt.Errorf("migración: %w", err)
			}
		}
	}
	return &App{db: db, attempts: make(map[string]attempt)}, nil
}
func (a *App) Close() { a.db.Close() }
func (a *App) Bootstrap(username, password string) error {
	if len(username) < 3 || len(password) < 12 || len(password) > 72 {
		return errors.New("ADMIN_USER mínimo 3 caracteres y ADMIN_PASSWORD entre 12 y 72 bytes")
	}
	hash, err := bcrypt.GenerateFromPassword([]byte(password), 12)
	if err != nil {
		return err
	}
	_, err = a.db.Exec("INSERT INTO users(name,username,password_hash,role) VALUES('Administrador',?,?, 'admin') ON DUPLICATE KEY UPDATE username=username", username, string(hash))
	return err
}
func jsonResponse(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}
func decode(r *http.Request, v any) error {
	d := json.NewDecoder(io.LimitReader(r.Body, 65537))
	d.DisallowUnknownFields()
	if err := d.Decode(v); err != nil {
		return fail(400, "Datos inválidos")
	}
	if d.Decode(&struct{}{}) != io.EOF {
		return fail(400, "Solo se permite un objeto JSON")
	}
	return nil
}
func (a *App) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
		defer cancel()
		if a.db.PingContext(ctx) != nil {
			jsonResponse(w, 503, map[string]string{"status": "unavailable"})
			return
		}
		jsonResponse(w, 200, map[string]string{"status": "ok"})
	})
	mux.HandleFunc("POST /api/v1/auth/login", a.login)
	mux.HandleFunc("/api/v1/", a.auth)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			if recover() != nil {
				jsonResponse(w, 500, map[string]string{"error": "Error interno"})
			}
		}()
		mux.ServeHTTP(w, r)
	})
}
func tokenHash(s string) string { v := sha256.Sum256([]byte(s)); return hex.EncodeToString(v[:]) }
func (a *App) login(w http.ResponseWriter, r *http.Request) {
	var p struct {
		Username string `json:"username"`
		Password string `json:"password"`
	}
	if e := decode(r, &p); e != nil {
		jsonResponse(w, 400, map[string]string{"error": e.Error()})
		return
	}
	p.Username = strings.ToLower(strings.TrimSpace(p.Username))
	key := p.Username
	a.loginMu.Lock()
	v := a.attempts[key]
	if time.Now().After(v.Until) {
		v = attempt{Until: time.Now().Add(10 * time.Minute)}
	}
	v.Count++
	a.attempts[key] = v
	if len(a.attempts) > 10000 {
		for k, t := range a.attempts {
			if time.Now().After(t.Until) {
				delete(a.attempts, k)
			}
		}
	}
	a.loginMu.Unlock()
	if v.Count > 10 {
		jsonResponse(w, 429, map[string]string{"error": "Demasiados intentos. Espera diez minutos."})
		return
	}
	var u User
	var hash string
	err := a.db.QueryRowContext(r.Context(), "SELECT id,name,username,role,active,password_hash FROM users WHERE username=?", p.Username).Scan(&u.ID, &u.Name, &u.Username, &u.Role, &u.Active, &hash)
	if err != nil || !u.Active || bcrypt.CompareHashAndPassword([]byte(hash), []byte(p.Password)) != nil {
		jsonResponse(w, 401, map[string]string{"error": "Usuario o contraseña incorrectos"})
		return
	}
	b := make([]byte, 32)
	if _, err = rand.Read(b); err != nil {
		jsonResponse(w, 500, map[string]string{"error": "Error de sesión"})
		return
	}
	token := hex.EncodeToString(b)
	expires := time.Now().UTC().Add(12 * time.Hour)
	if _, err = a.db.ExecContext(r.Context(), "INSERT INTO sessions(token_hash,user_id,expires_at) VALUES(?,?,?)", tokenHash(token), u.ID, expires); err != nil {
		jsonResponse(w, 500, map[string]string{"error": "No se pudo crear sesión"})
		return
	}
	a.loginMu.Lock()
	delete(a.attempts, key)
	a.loginMu.Unlock()
	_, _ = a.db.ExecContext(r.Context(), "DELETE FROM sessions WHERE expires_at < UTC_TIMESTAMP()")
	jsonResponse(w, 200, map[string]any{"token": token, "expires_at": expires, "user": u})
}
func (a *App) auth(w http.ResponseWriter, r *http.Request) {
	token := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
	var u User
	err := a.db.QueryRowContext(r.Context(), "SELECT u.id,u.name,u.username,u.role,u.active FROM sessions s JOIN users u ON u.id=s.user_id WHERE s.token_hash=? AND s.expires_at>UTC_TIMESTAMP() AND u.active=1", tokenHash(token)).Scan(&u.ID, &u.Name, &u.Username, &u.Role, &u.Active)
	if err != nil {
		jsonResponse(w, 401, map[string]string{"error": "Inicia sesión nuevamente"})
		return
	}
	result, err := a.route(r, u, token)
	if err != nil {
		var e *apiError
		if errors.As(err, &e) {
			jsonResponse(w, e.Code, map[string]string{"error": e.Message})
		} else {
			jsonResponse(w, 500, map[string]string{"error": "No se pudo completar la operación"})
		}
		return
	}
	jsonResponse(w, 200, result)
}
func today() string {
	loc, _ := time.LoadLocation("America/Bogota")
	return time.Now().In(loc).Format("2006-01-02")
}
func validDate(s string) bool { _, e := time.Parse("2006-01-02", s); return e == nil }
func (a *App) route(r *http.Request, u User, token string) (any, error) {
	path := strings.TrimPrefix(r.URL.Path, "/api/v1")
	ctx := r.Context()
	if path == "/students" || path == "/attendance" {
		return a.attendance(r, u, path)
	}
	if r.Method == "GET" && path == "/me" {
		return u, nil
	}
	if r.Method == "POST" && path == "/auth/logout" {
		_, e := a.db.ExecContext(ctx, "DELETE FROM sessions WHERE token_hash=?", tokenHash(token))
		return map[string]bool{"ok": true}, e
	}
	if r.Method == "POST" && path == "/auth/password" {
		var p struct {
			Current  string `json:"current"`
			Password string `json:"password"`
		}
		if e := decode(r, &p); e != nil {
			return nil, e
		}
		if len(p.Password) < 12 || len(p.Password) > 72 {
			return nil, fail(400, "La contraseña debe tener entre 12 y 72 bytes")
		}
		var old string
		_ = a.db.QueryRowContext(ctx, "SELECT password_hash FROM users WHERE id=?", u.ID).Scan(&old)
		if bcrypt.CompareHashAndPassword([]byte(old), []byte(p.Current)) != nil {
			return nil, fail(403, "Contraseña actual incorrecta")
		}
		h, _ := bcrypt.GenerateFromPassword([]byte(p.Password), 12)
		_, e := a.db.ExecContext(ctx, "UPDATE users SET password_hash=? WHERE id=?", string(h), u.ID)
		if e == nil {
			_, e = a.db.ExecContext(ctx, "DELETE FROM sessions WHERE user_id=? AND token_hash<>?", u.ID, tokenHash(token))
		}
		return map[string]bool{"ok": true}, e
	}
	if r.Method == "GET" && (path == "/status" || path == "/schedule" || path == "/teacher/turns") {
		date := r.URL.Query().Get("date")
		if date == "" {
			date = today()
		}
		if !validDate(date) {
			return nil, fail(400, "Fecha inválida")
		}
		d, e := a.loadDay(ctx, date)
		if e != nil {
			return nil, e
		}
		if path == "/teacher/turns" {
			if u.Role == "student" {
				return nil, fail(403, "Acceso restringido")
			}
			filtered := []Turn{}
			for _, t := range d.Turns {
				if t.TeacherID == u.ID {
					filtered = append(filtered, t)
				}
			}
			d.Turns = filtered
		}
		if u.Role == "student" {
			for i := range d.Turns {
				d.Turns[i].TeacherID = 0
			}
		}
		return map[string]any{"day": d, "server_time": time.Now().UTC()}, nil
	}
	if r.Method == "POST" && strings.HasPrefix(path, "/turns/") && strings.HasSuffix(path, "/finish") {
		if u.Role == "student" {
			return nil, fail(403, "Solo el docente asignado puede finalizar")
		}
		id, e := strconv.ParseInt(strings.TrimSuffix(strings.TrimPrefix(path, "/turns/"), "/finish"), 10, 64)
		if e != nil {
			return nil, fail(400, "Turno inválido")
		}
		return a.change(r, u, "finish", id)
	}
	if !strings.HasPrefix(path, "/admin/") {
		return nil, fail(404, "Ruta no encontrada")
	}
	if u.Role != "admin" {
		return nil, fail(403, "Solo administradores")
	}
	switch {
	case path == "/admin/users" && r.Method == "GET":
		rows, e := a.db.QueryContext(ctx, "SELECT id,name,username,role,active FROM users ORDER BY name LIMIT 1000")
		if e != nil {
			return nil, e
		}
		defer rows.Close()
		items := []User{}
		for rows.Next() {
			var v User
			if e = rows.Scan(&v.ID, &v.Name, &v.Username, &v.Role, &v.Active); e != nil {
				return nil, e
			}
			items = append(items, v)
		}
		return items, rows.Err()
	case path == "/admin/users" && r.Method == "POST":
		var p struct {
			Name     string `json:"name"`
			Username string `json:"username"`
			Password string `json:"password"`
			Role     string `json:"role"`
		}
		if e := decode(r, &p); e != nil {
			return nil, e
		}
		p.Username = strings.ToLower(strings.TrimSpace(p.Username))
		p.Name = strings.TrimSpace(p.Name)
		if p.Name == "" || len(p.Name) > 120 || len(p.Username) < 3 || len(p.Username) > 80 || len(p.Password) < 12 || len(p.Password) > 72 || (p.Role != "admin" && p.Role != "teacher" && p.Role != "student") {
			return nil, fail(400, "Revisa nombre, usuario, rol y contraseña (12–72 bytes)")
		}
		h, e := bcrypt.GenerateFromPassword([]byte(p.Password), 12)
		if e != nil {
			return nil, e
		}
		res, e := a.db.ExecContext(ctx, "INSERT INTO users(name,username,password_hash,role) VALUES(?,?,?,?)", p.Name, p.Username, string(h), p.Role)
		if e != nil {
			return nil, fail(409, "No se pudo crear: revisa si el usuario ya existe")
		}
		id, _ := res.LastInsertId()
		return map[string]any{"id": id}, a.audit(ctx, u.ID, "user.create", id, map[string]string{"role": p.Role})
	case strings.HasPrefix(path, "/admin/users/") && r.Method == "PATCH":
		id, e := strconv.ParseInt(strings.TrimPrefix(path, "/admin/users/"), 10, 64)
		if e != nil {
			return nil, fail(400, "Usuario inválido")
		}
		return a.updateUser(r, u, id)
	case path == "/admin/groups" && r.Method == "GET":
		rows, e := a.db.QueryContext(ctx, "SELECT id,name,teacher_id,active FROM school_groups ORDER BY name")
		if e != nil {
			return nil, e
		}
		defer rows.Close()
		items := []Group{}
		for rows.Next() {
			var v Group
			if e = rows.Scan(&v.ID, &v.Name, &v.TeacherID, &v.Active); e != nil {
				return nil, e
			}
			items = append(items, v)
		}
		return items, rows.Err()
	case path == "/admin/groups" && r.Method == "POST":
		var p struct {
			Name      string `json:"name"`
			TeacherID int64  `json:"teacher_id"`
		}
		if e := decode(r, &p); e != nil {
			return nil, e
		}
		p.Name = strings.TrimSpace(p.Name)
		if p.Name == "" || len(p.Name) > 80 {
			return nil, fail(400, "Nombre de grupo inválido")
		}
		var n int
		_ = a.db.QueryRowContext(ctx, "SELECT COUNT(*) FROM users WHERE id=? AND role='teacher' AND active=1", p.TeacherID).Scan(&n)
		if n != 1 {
			return nil, fail(400, "Selecciona un docente activo")
		}
		res, e := a.db.ExecContext(ctx, "INSERT INTO school_groups(name,teacher_id) VALUES(?,?)", p.Name, p.TeacherID)
		if e != nil {
			return nil, fail(409, "No se pudo crear el grupo; revisa si ya existe")
		}
		id, _ := res.LastInsertId()
		return map[string]any{"id": id}, a.audit(ctx, u.ID, "group.create", id, p)
	case path == "/admin/service-days" && r.Method == "POST":
		return a.createDay(r, u)
	case strings.HasPrefix(path, "/admin/service-days/") && r.Method == "POST":
		parts := strings.Split(strings.TrimPrefix(path, "/admin/service-days/"), "/")
		if len(parts) != 2 {
			return nil, fail(404, "Ruta inválida")
		}
		id, e := strconv.ParseInt(parts[0], 10, 64)
		if e != nil {
			return nil, fail(400, "Jornada inválida")
		}
		if parts[1] != "start" && parts[1] != "pause" && parts[1] != "resume" {
			return nil, fail(404, "Acción inválida")
		}
		return a.change(r, u, parts[1], id)
	case strings.HasPrefix(path, "/admin/turns/") && r.Method == "POST":
		parts := strings.Split(strings.TrimPrefix(path, "/admin/turns/"), "/")
		if len(parts) != 2 || (parts[1] != "skip" && parts[1] != "cancel") {
			return nil, fail(404, "Acción inválida")
		}
		id, e := strconv.ParseInt(parts[0], 10, 64)
		if e != nil {
			return nil, fail(400, "Turno inválido")
		}
		return a.change(r, u, parts[1], id)
	case path == "/admin/audit" && r.Method == "GET":
		rows, e := a.db.QueryContext(ctx, "SELECT a.id,u.name,a.action,a.resource_id,a.detail,a.created_at FROM audit_events a JOIN users u ON u.id=a.user_id ORDER BY a.id DESC LIMIT 100")
		if e != nil {
			return nil, e
		}
		defer rows.Close()
		out := []map[string]any{}
		for rows.Next() {
			var id, res int64
			var name, action, detail string
			var at time.Time
			if e = rows.Scan(&id, &name, &action, &res, &detail, &at); e != nil {
				return nil, e
			}
			out = append(out, map[string]any{"id": id, "actor": name, "action": action, "resource_id": res, "detail": json.RawMessage(detail), "created_at": at})
		}
		return out, rows.Err()
	}
	return nil, fail(404, "Ruta no encontrada")
}
func (a *App) loadDay(ctx context.Context, date string) (Day, error) {
	d := Day{Date: date, Status: "unconfigured", Turns: []Turn{}}
	var raw []byte
	var id, v int64
	e := a.db.QueryRowContext(ctx, "SELECT id,state,version FROM service_days WHERE service_date=?", date).Scan(&id, &raw, &v)
	if e == sql.ErrNoRows {
		return d, nil
	}
	if e != nil {
		return d, e
	}
	e = json.Unmarshal(raw, &d)
	d.ID = id
	d.Version = v
	return d, e
}
func (a *App) audit(ctx context.Context, uid int64, action string, id int64, detail any) error {
	b, e := json.Marshal(detail)
	if e != nil {
		return e
	}
	_, e = a.db.ExecContext(ctx, "INSERT INTO audit_events(user_id,action,resource_id,detail) VALUES(?,?,?,?)", uid, action, id, b)
	return e
}
func (a *App) createDay(r *http.Request, u User) (any, error) {
	var p struct {
		Date     string  `json:"date"`
		Start    string  `json:"start"`
		GroupIDs []int64 `json:"group_ids"`
		Minutes  int     `json:"minutes"`
	}
	if e := decode(r, &p); e != nil {
		return nil, e
	}
	if !validDate(p.Date) || p.Minutes < 1 || p.Minutes > 120 || len(p.GroupIDs) == 0 || len(p.GroupIDs) > 100 {
		return nil, fail(400, "Fecha, grupos o duración inválidos")
	}
	loc, _ := time.LoadLocation("America/Bogota")
	start, e := time.ParseInLocation("2006-01-02 15:04", p.Date+" "+p.Start, loc)
	if e != nil {
		return nil, fail(400, "Hora inválida; usa HH:MM")
	}
	d := Day{Date: p.Date, Status: "scheduled", Version: 1, Turns: []Turn{}}
	seen := map[int64]bool{}
	for i, id := range p.GroupIDs {
		if seen[id] {
			return nil, fail(400, "Grupo repetido")
		}
		seen[id] = true
		var g Group
		e = a.db.QueryRowContext(r.Context(), "SELECT g.id,g.name,g.teacher_id FROM school_groups g JOIN users u ON u.id=g.teacher_id WHERE g.id=? AND g.active=1 AND u.active=1", id).Scan(&g.ID, &g.Name, &g.TeacherID)
		if e != nil {
			return nil, fail(400, "Grupo o docente no disponible")
		}
		scheduled := start.Add(time.Duration(i*p.Minutes) * time.Minute)
		if scheduled.In(loc).Format("2006-01-02") != p.Date {
			return nil, fail(400, "La programación debe caber en el mismo día")
		}
		d.Turns = append(d.Turns, Turn{ID: int64(i + 1), GroupID: g.ID, GroupName: g.Name, TeacherID: g.TeacherID, Scheduled: scheduled.Format(time.RFC3339), Duration: p.Minutes * 60, Status: "pending"})
	}
	raw, _ := json.Marshal(d)
	tx, e := a.db.BeginTx(r.Context(), nil)
	if e != nil {
		return nil, e
	}
	defer tx.Rollback()
	res, e := tx.ExecContext(r.Context(), "INSERT INTO service_days(service_date,state) VALUES(?,?)", p.Date, raw)
	if e != nil {
		return nil, fail(409, "Ya existe una jornada para esta fecha")
	}
	d.ID, _ = res.LastInsertId()
	detail, _ := json.Marshal(map[string]string{"date": p.Date})
	_, e = tx.ExecContext(r.Context(), "INSERT INTO audit_events(user_id,action,resource_id,detail) VALUES(?,'day.create',?,?)", u.ID, d.ID, detail)
	if e != nil {
		return nil, e
	}
	if e = tx.Commit(); e != nil {
		return nil, e
	}
	return d, nil
}

type command struct {
	Date    string `json:"date"`
	Version int64  `json:"version"`
	Reason  string `json:"reason"`
}

func (a *App) change(r *http.Request, u User, action string, id int64) (any, error) {
	var p command
	if e := decode(r, &p); e != nil {
		return nil, e
	}
	if !validDate(p.Date) {
		return nil, fail(400, "Fecha inválida")
	}
	if p.Date != today() {
		return nil, fail(409, "Solo se puede operar la jornada de hoy")
	}
	tx, e := a.db.BeginTx(r.Context(), nil)
	if e != nil {
		return nil, e
	}
	defer tx.Rollback()
	var raw []byte
	var dayID, version int64
	e = tx.QueryRowContext(r.Context(), "SELECT id,state,version FROM service_days WHERE service_date=? FOR UPDATE", p.Date).Scan(&dayID, &raw, &version)
	if e == sql.ErrNoRows {
		return nil, fail(404, "Jornada no encontrada")
	}
	if e != nil {
		return nil, e
	}
	var d Day
	if e = json.Unmarshal(raw, &d); e != nil {
		return nil, e
	}
	d.ID = dayID
	d.Version = version
	// A completed turn is idempotent; replaying it cannot finish the next one.
	if action == "finish" {
		for _, t := range d.Turns {
			if t.ID == id && t.Status == "finished" && (u.Role == "admin" || t.TeacherID == u.ID) {
				return d, nil
			}
		}
	}
	if version != p.Version {
		return nil, fail(409, "La jornada cambió. Actualiza e intenta de nuevo")
	}
	if (action == "start" || action == "pause" || action == "resume") && id != dayID {
		return nil, fail(409, "Jornada incorrecta")
	}
	now := time.Now().UTC()
	if e = transition(&d, u, action, id, p.Reason, now); e != nil {
		return nil, e
	}
	d.Version++
	raw, e = json.Marshal(d)
	if e != nil {
		return nil, e
	}
	if _, e = tx.ExecContext(r.Context(), "UPDATE service_days SET state=?,version=? WHERE id=?", raw, d.Version, dayID); e != nil {
		return nil, e
	}
	detail, _ := json.Marshal(map[string]any{"date": p.Date, "turn_id": id, "reason": p.Reason, "version": d.Version})
	if _, e = tx.ExecContext(r.Context(), "INSERT INTO audit_events(user_id,action,resource_id,detail) VALUES(?,?,?,?)", u.ID, action, dayID, detail); e != nil {
		return nil, e
	}
	if e = tx.Commit(); e != nil {
		return nil, e
	}
	return d, nil
}
func transition(d *Day, u User, action string, id int64, reason string, now time.Time) error {
	if action != "finish" && u.Role != "admin" {
		return fail(403, "Solo administradores")
	}
	switch action {
	case "start":
		if d.Status != "scheduled" {
			return fail(409, "La jornada ya inició")
		}
		d.Status = "running"
		advance(d, now)
		return nil
	case "pause":
		if d.Status != "running" {
			return fail(409, "La jornada no está en curso")
		}
		d.Status = "paused"
		d.PausedAt = &now
		return nil
	case "resume":
		if d.Status != "paused" || d.PausedAt == nil {
			return fail(409, "La jornada no está pausada")
		}
		for i := range d.Turns {
			if d.Turns[i].Status == "active" {
				d.Turns[i].PausedSeconds += now.Sub(*d.PausedAt).Seconds()
			}
		}
		d.PausedAt = nil
		d.Status = "running"
		return nil
	}
	if d.Status != "running" && d.Status != "scheduled" {
		return fail(409, "La jornada no permite esta acción")
	}
	for i := range d.Turns {
		t := &d.Turns[i]
		if t.ID != id {
			continue
		}
		if action == "finish" {
			if u.Role != "admin" && (u.Role != "teacher" || t.TeacherID != u.ID) {
				return fail(403, "Este turno no está asignado a tu usuario")
			}
			if t.Status != "active" || d.Status != "running" {
				return fail(409, "El turno no está activo")
			}
			t.Status = "finished"
		} else {
			if strings.TrimSpace(reason) == "" || len(reason) > 500 {
				return fail(400, "Indica un motivo de hasta 500 caracteres")
			}
			if t.Status != "active" && t.Status != "pending" {
				return fail(409, "El turno ya terminó")
			}
			if action == "skip" {
				t.Status = "skipped"
			} else if action == "cancel" {
				t.Status = "cancelled"
			} else {
				return fail(400, "Acción inválida")
			}
		}
		t.FinishedAt = &now
		if d.Status == "running" {
			advance(d, now)
		}
		return nil
	}
	return fail(404, "Turno no encontrado")
}
func advance(d *Day, now time.Time) {
	for _, t := range d.Turns {
		if t.Status == "active" {
			return
		}
	}
	for i := range d.Turns {
		if d.Turns[i].Status == "pending" {
			d.Turns[i].Status = "active"
			d.Turns[i].StartedAt = &now
			return
		}
	}
	d.Status = "finished"
}
