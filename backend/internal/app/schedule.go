package app

import (
	"database/sql"
	"encoding/json"
	"errors"
	"net/http"
	"time"
)

type scheduleTurn struct {
	ID      int64  `json:"id"`
	GroupID int64  `json:"group_id"`
	Start   string `json:"start"`
	Minutes int    `json:"minutes"`
}

func validateSchedule(date string, inputs []scheduleTurn) ([]Turn, error) {
	if !validDate(date) || len(inputs) == 0 || len(inputs) > 100 {
		return nil, fail(400, "Selecciona fecha y entre 1 y 100 grupos")
	}
	loc, _ := time.LoadLocation("America/Bogota")
	groups, ids := map[int64]bool{}, map[int64]bool{}
	turns := make([]Turn, 0, len(inputs))
	var end time.Time
	for _, p := range inputs {
		if p.ID < 0 || p.GroupID < 1 || groups[p.GroupID] || p.Minutes < 1 || p.Minutes > 120 || (p.ID != 0 && ids[p.ID]) {
			return nil, fail(400, "Revisa grupos, identificadores y duración (1–120 minutos)")
		}
		groups[p.GroupID] = true
		ids[p.ID] = true
		start, e := time.ParseInLocation("2006-01-02 15:04", date+" "+p.Start, loc)
		if e != nil {
			return nil, fail(400, "Hora inválida; usa HH:MM")
		}
		next := start.Add(time.Duration(p.Minutes) * time.Minute)
		if (!end.IsZero() && start.Before(end)) || next.Format("2006-01-02") != date {
			return nil, fail(400, "Los horarios deben estar ordenados, sin cruces y dentro del mismo día")
		}
		end = next
		turns = append(turns, Turn{ID: p.ID, GroupID: p.GroupID, Scheduled: start.Format(time.RFC3339), Duration: p.Minutes * 60, Status: "pending"})
	}
	return turns, nil
}

func (a *App) updateDay(r *http.Request, u User, id int64) (any, error) {
	var p struct {
		Date    string         `json:"date"`
		Version int64          `json:"version"`
		Turns   []scheduleTurn `json:"turns"`
	}
	if e := decode(r, &p); e != nil {
		return nil, e
	}
	if id < 1 || p.Version < 1 {
		return nil, fail(400, "Jornada o versión inválida")
	}
	turns, e := validateSchedule(p.Date, p.Turns)
	if e != nil {
		return nil, e
	}
	if p.Date < today() {
		return nil, fail(409, "No se puede editar una jornada pasada")
	}
	ctx := r.Context()
	tx, e := a.db.BeginTx(ctx, nil)
	if e != nil {
		return nil, e
	}
	defer tx.Rollback()
	var raw []byte
	var version int64
	var date string
	e = tx.QueryRowContext(ctx, "SELECT DATE_FORMAT(service_date,'%Y-%m-%d'),state,version FROM service_days WHERE id=? FOR UPDATE", id).Scan(&date, &raw, &version)
	if errors.Is(e, sql.ErrNoRows) {
		return nil, fail(404, "Jornada no encontrada")
	}
	if e != nil {
		return nil, e
	}
	if date != p.Date || version != p.Version {
		return nil, fail(409, "La jornada cambió. Vuelve a abrir el editor")
	}
	var d Day
	if e = json.Unmarshal(raw, &d); e != nil {
		return nil, e
	}
	if d.Status != "scheduled" && d.Status != "running" && d.Status != "paused" {
		return nil, fail(409, "Esta jornada ya terminó")
	}
	existing := map[int64]Turn{}
	var nextID int64
	for _, t := range d.Turns {
		existing[t.ID] = t
		if t.ID > nextID {
			nextID = t.ID
		}
	}
	var activeEnd time.Time
	for _, t := range d.Turns {
		if t.Status == "active" {
			at, _ := time.Parse(time.RFC3339, t.Scheduled)
			activeEnd = at.Add(time.Duration(t.Duration) * time.Second)
		}
	}
	kept := map[int64]bool{}
	for i := range turns {
		t := &turns[i]
		old, found := existing[t.ID]
		if t.ID != 0 && !found {
			return nil, fail(400, "Turno desconocido")
		}
		if found && old.Status != "pending" {
			oldAt, _ := time.Parse(time.RFC3339, old.Scheduled)
			newAt, _ := time.Parse(time.RFC3339, t.Scheduled)
			if old.GroupID != t.GroupID || !oldAt.Equal(newAt) || old.Duration != t.Duration {
				return nil, fail(409, "El turno activo y los turnos finalizados no se pueden modificar ni reordenar")
			}
			*t = old
		} else {
			at, _ := time.Parse(time.RFC3339, t.Scheduled)
			if !activeEnd.IsZero() && at.Before(activeEnd) {
				return nil, fail(409, "Los turnos pendientes deben quedar después del turno activo")
			}
			if !found {
				nextID++
				t.ID = nextID
			}
			var g Group
			e = tx.QueryRowContext(ctx, "SELECT g.id,g.name,g.teacher_id FROM school_groups g JOIN users u ON u.id=g.teacher_id WHERE g.id=? AND g.active=1 AND u.active=1 AND u.role='teacher'", t.GroupID).Scan(&g.ID, &g.Name, &g.TeacherID)
			if e != nil {
				if errors.Is(e, sql.ErrNoRows) {
					return nil, fail(400, "Grupo o docente no disponible")
				}
				return nil, e
			}
			t.GroupName = g.Name
			t.TeacherID = g.TeacherID
		}
		kept[t.ID] = true
	}
	// Preserve the relative order and all state of every non-pending turn.
	oldOrder, newOrder := []int64{}, []int64{}
	for _, t := range d.Turns {
		if t.Status != "pending" {
			if !kept[t.ID] {
				return nil, fail(409, "No puedes eliminar turnos que ya fueron atendidos, omitidos o iniciados")
			}
			oldOrder = append(oldOrder, t.ID)
		}
	}
	for _, t := range turns {
		if t.Status != "pending" {
			newOrder = append(newOrder, t.ID)
		}
	}
	for i, id := range oldOrder {
		if newOrder[i] != id {
			return nil, fail(409, "No puedes cambiar el orden del historial")
		}
	}
	d.ID = id
	d.Date = date
	d.Version = version + 1
	d.Turns = turns
	raw, e = json.Marshal(d)
	if e != nil {
		return nil, e
	}
	if _, e = tx.ExecContext(ctx, "UPDATE service_days SET state=?,version=? WHERE id=?", raw, d.Version, id); e != nil {
		return nil, e
	}
	detail, _ := json.Marshal(map[string]any{"date": date, "version": d.Version, "turns": p.Turns})
	if _, e = tx.ExecContext(ctx, "INSERT INTO audit_events(user_id,action,resource_id,detail) VALUES(?,'day.update',?,?)", u.ID, id, detail); e != nil {
		return nil, e
	}
	if e = tx.Commit(); e != nil {
		return nil, e
	}
	return d, nil
}
