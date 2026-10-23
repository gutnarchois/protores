# API de Protores · v1

Base de producción: `https://restaurante.in4.blue/api/v1`.

Todas las rutas excepto `POST /auth/login` y `GET /healthz` (fuera del prefijo) requieren `Authorization: Bearer TOKEN`. La sesión dura 12 horas; luego se inicia sesión nuevamente. Se almacena únicamente el hash del token en MySQL. El cliente conserva el token en almacenamiento seguro Android.

La referencia legible por herramientas se encuentra en [openapi.json](openapi.json).

## Acceso

`POST /auth/login`: `{"username":"USUARIO","password":"CONTRASEÑA"}`. Devuelve `token`, `expires_at` y `user` (`id`, `name`, `username`, `role`, `active`). Roles internos: `admin`, `teacher`, `student`.

`GET /me`: identidad de la sesión. `POST /auth/logout`: revoca esa sesión.

`POST /auth/password`: `{"current":"ACTUAL","password":"NUEVA"}`. Nueva contraseña entre 12 y 72 bytes. Revoca las otras sesiones del usuario.

## Consulta

`GET /status` y `GET /schedule`: devuelven `{"server_time":"FECHA_UTC","day":{...}}`. Aceptan `?date=AAAA-MM-DD`; por defecto hoy en Colombia. Sin programación: `day.status=unconfigured`, `day.id=0` y `day.turns=[]`.

Campos de jornada: `id`, `date`, `status`, `version`, `paused_at` opcional y `turns` ordenados.

Cada turno contiene `id`, `group_id`, `group_name`, `teacher_id` (0 en la consulta estudiantil), `scheduled` con zona, `duration_seconds`, `status`, `started_at`, `finished_at` y `paused_seconds`. El identificador de turno es local a la jornada; se interpreta junto con `date`.

Estados de jornada: `scheduled`, `running`, `paused`, `finished`. Estados de turno: `pending`, `active`, `finished`, `skipped`, `cancelled`.

`GET /teacher/turns` filtra los turnos asignados al docente autenticado. Estudiantes no tienen acceso a esta ruta.

El contador se calcula desde `started_at` usando la hora del servidor, la duración y el tiempo pausado. Al vencer no avanza automáticamente. Durante pausa se usa `paused_at` como instante de referencia. La aplicación actualiza el estado cada cinco segundos mientras está visible y al regresar del segundo plano.

## Administración

| Método | Ruta | Cuerpo o resultado |
| --- | --- | --- |
| GET | /admin/users | Hasta 1000 usuarios, sin hashes ni contraseñas |
| POST | /admin/users | `name`, `username`, `password` (12–72 bytes), `role` |
| PATCH | /admin/users/{id} | `name`, `username`, `active` y `password` opcionales; edición parcial de datos o acceso |
| GET | /admin/groups | Grupos y docente asignado |
| POST | /admin/groups | `name`, `teacher_id` de un docente activo |
| POST | /admin/service-days | `date`, `start` (HH:MM Colombia), `minutes` (1–120), `group_ids` en orden |
| GET | /admin/audit | Últimas 100 acciones, más recientes primero |

La versión inicial permite una programación por fecha. Antes de crearla, revisar orden, docentes, hora y duración. La edición de una programación existente y de grupos queda para la siguiente iteración; durante la atención el administrador puede omitir o cancelar con motivo. Las asignaciones se copian a la programación para mantener su historial.

## Cambios de estado

Cuerpo obligatorio: `{"date":"AAAA-MM-DD","version":VERSION_ACTUAL}`. Las acciones de omitir y cancelar exigen además `reason` de 1 a 500 caracteres. Solo se opera la jornada de hoy.

- Admin: `POST /admin/service-days/{id}/start`, `/pause`, `/resume`.
- Docente asignado o admin: `POST /turns/{id}/finish`.
- Admin: `POST /admin/turns/{id}/skip`, `/cancel`.

El inicio es manual; el horario indica la planificación. Cada activación comienza la duración real del grupo y una finalización temprana adelanta al siguiente. Pausar bloquea finalizaciones. Una jornada terminada no se puede reiniciar.

El servidor bloquea la fila de la jornada en una transacción MySQL. Guarda estado y auditoría juntos. Finalizar de nuevo un turno ya finalizado devuelve el estado vigente sin avanzar otra vez. Una versión desactualizada en otras acciones devuelve 409. No reintentar una acción de avance con otra versión automáticamente: consultar y pedir nueva confirmación.

## Errores

JSON `{"error":"Descripción"}`. 400: datos inválidos; 401: sesión inválida o vencida; 403: permisos insuficientes; 404: recurso/ruta inexistente; 409: conflicto; 429: intentos de inicio de sesión excedidos; 500: operación fallida. En errores de red, volver a consultar antes de confirmar cambios.

## Persistencia

MySQL conserva usuarios, sesiones, grupos, jornadas y auditoría en tablas InnoDB. En esta versión, los turnos son un documento JSON dentro de `service_days.state`; el bloqueo de esa fila garantiza una sola secuencia activa. No se implementaron tablas independientes `turns`/`operations`: la repetición segura de finalización se basa en el estado persistido del turno. Separarlas será una migración posterior si los reportes lo requieren.

## Edición de usuarios · versión 0.1.1

Cambio desplegado y verificado en la API de producción el 23 de octubre de 2026. `PATCH /admin/users/{id}` acepta `name`, `username`, `active` y `password` como campos opcionales; debe enviarse al menos un cambio. Los campos omitidos se conservan. Nombre obligatorio de hasta 120 bytes; usuario de 3 a 80 bytes, normalizado a minúsculas y sin espacios exteriores. Un usuario duplicado devuelve 409 y un identificador inexistente, 404.

Solo administradores pueden editar. Pueden corregir su propio nombre y usuario; su contraseña se cambia desde `/auth/password` y no pueden desactivar su propia cuenta. Nombre y usuario conservan sesiones; activar/desactivar o restablecer contraseña las revoca. Los cambios y la auditoría se guardan en una transacción. El rol y las asignaciones no se editan con esta operación.
