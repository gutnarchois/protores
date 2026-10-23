package app

import (
	"database/sql"
	"encoding/json"
	"errors"
	"net/http"
	"strings"

	"github.com/go-sql-driver/mysql"
	"golang.org/x/crypto/bcrypt"
)

func (a *App) updateUser(r *http.Request, actor User, id int64) (any, error) {
	var p struct {
		Name     *string `json:"name"`
		Username *string `json:"username"`
		Active   *bool   `json:"active"`
		Password string  `json:"password"`
	}
	if err := decode(r, &p); err != nil {
		return nil, err
	}
	if id < 1 || (p.Name == nil && p.Username == nil && p.Active == nil && p.Password == "") {
		return nil, fail(400, "Indica los datos del usuario que deseas cambiar")
	}
	if p.Name != nil {
		*p.Name = strings.TrimSpace(*p.Name)
		if *p.Name == "" || len(*p.Name) > 120 {
			return nil, fail(400, "Nombre obligatorio, máximo 120 bytes")
		}
	}
	if p.Username != nil {
		*p.Username = strings.ToLower(strings.TrimSpace(*p.Username))
		if len(*p.Username) < 3 || len(*p.Username) > 80 {
			return nil, fail(400, "Usuario: entre 3 y 80 bytes")
		}
	}
	if id == actor.ID && (p.Active != nil || p.Password != "") {
		return nil, fail(400, "Para cambiar tu contraseña usa el candado; no puedes cambiar tu propio estado")
	}
	var hash []byte
	if p.Password != "" {
		if len(p.Password) < 12 || len(p.Password) > 72 {
			return nil, fail(400, "Contraseña: 12–72 bytes")
		}
		var err error
		hash, err = bcrypt.GenerateFromPassword([]byte(p.Password), 12)
		if err != nil {
			return nil, err
		}
	}
	ctx := r.Context()
	tx, err := a.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	var target User
	err = tx.QueryRowContext(ctx, "SELECT id,name,username,role,active FROM users WHERE id=? FOR UPDATE", id).
		Scan(&target.ID, &target.Name, &target.Username, &target.Role, &target.Active)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, fail(404, "Usuario no encontrado")
	}
	if err != nil {
		return nil, err
	}
	if p.Name != nil {
		target.Name = *p.Name
	}
	if p.Username != nil {
		target.Username = *p.Username
	}
	if p.Active != nil {
		target.Active = *p.Active
	}
	_, err = tx.ExecContext(ctx, "UPDATE users SET name=?,username=?,active=? WHERE id=?", target.Name, target.Username, target.Active, id)
	if err != nil {
		var myErr *mysql.MySQLError
		if errors.As(err, &myErr) && myErr.Number == 1062 {
			return nil, fail(409, "El nombre de usuario ya está en uso")
		}
		return nil, err
	}
	if hash != nil {
		if _, err = tx.ExecContext(ctx, "UPDATE users SET password_hash=? WHERE id=?", string(hash), id); err != nil {
			return nil, err
		}
	}
	// Editing a display/login name preserves sessions. Access changes revoke them.
	if p.Active != nil || hash != nil {
		if _, err = tx.ExecContext(ctx, "DELETE FROM sessions WHERE user_id=?", id); err != nil {
			return nil, err
		}
	}
	detail, err := json.Marshal(map[string]any{"name": target.Name, "username": target.Username, "active": target.Active, "password_reset": hash != nil})
	if err != nil {
		return nil, err
	}
	if _, err = tx.ExecContext(ctx, "INSERT INTO audit_events(user_id,action,resource_id,detail) VALUES(?, 'user.update', ?, ?)", actor.ID, id, detail); err != nil {
		return nil, err
	}
	if err = tx.Commit(); err != nil {
		return nil, err
	}
	return map[string]bool{"ok": true}, nil
}
