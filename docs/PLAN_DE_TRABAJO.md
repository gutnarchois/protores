# Plan de trabajo — Protores

Fecha de elaboración: 23 de octubre de 2026.
Institución: Institución Educativa Cristóbal Colón, sede Mariano Ramos (nombre oficial por confirmar).
Estado: MVP implementado; API desplegada y verificada; APK firmado 0.1.0 publicado en GitHub Releases. Piloto institucional pendiente.

## 1. Objetivo

Crear una aplicación Android en Flutter para organizar la atención del Programa de Alimentación Escolar (PAE) por grado y grupo. El administrador configura los horarios; los docentes informan cuando termina la atención de su grupo; los estudiantes consultan quién está en el restaurante, cuánto tiempo queda y quién sigue.

La aplicación consumirá una API en Go con MySQL, alojada en el VPS Ubuntu asociado a in4.blue. El APK se publicará en GitHub Releases y se ofrecerá desde iecc.page.gd.

## 2. Alcance de la primera versión

| Rol | Funciones |
| --- | --- |
| Administrador | Crear y desactivar usuarios docentes, registrar grados y grupos, asignar docentes, configurar horarios y duración, ordenar turnos, iniciar o pausar la jornada, reanudar, saltar o cancelar un turno y consultar el historial. |
| Docente | Iniciar sesión, consultar sus grupos y turnos, ver el estado general y marcar como finalizado únicamente el turno activo que tenga asignado. |
| Estudiante | Consultar el grupo actual, tiempo restante, siguiente grupo y programación del día; sin permisos de modificación. |

El MVP tendrá los tres roles solicitados: administrador, docente y estudiante. El estudiante iniciará sesión y tendrá permisos de solo lectura, sin acceso a usuarios, asignaciones ni auditoría. Para minimizar datos personales, se definirá con la institución el mecanismo de alta y acceso estudiantil. Una consulta pública sin cuenta será opcional y deberá acordarse antes de habilitarla.

Fuera del MVP: inventario de alimentos, registro individual de consumo, biometría, información nutricional y múltiples restaurantes simultáneos.

## 3. Reglas de los turnos

1. El administrador configura una jornada con fecha, hora de inicio, grupos, orden y duración por turno; no se permiten posiciones duplicadas ni horarios incompatibles.
2. Solo puede existir un turno activo por jornada y restaurante. El administrador inicia la atención; hasta entonces se muestra «pendiente de inicio».
3. Al finalizar su atención, el docente confirma una vez. La API registra quién finalizó, cierra el turno y activa el siguiente en una sola transacción.
4. El horario es una referencia de planificación. La duración real se cuenta desde la activación del turno; finalizar temprano adelanta el siguiente. Si se requiere esperar hasta la hora programada, esa política se definirá antes de implementar el motor.
5. Llegar a cero muestra «tiempo excedido» y el contador restante se queda en cero. Por defecto no se avanza automáticamente: la confirmación del docente evita llamar a otro grupo mientras el restaurante sigue ocupado.
6. El administrador puede finalizar o saltar un turno con motivo obligatorio. Los cambios quedan registrados en auditoría.
7. Pausar congela el contador y bloquea el avance habitual; reanudar conserva el tiempo restante. El servidor conserva los instantes y duración acumulada de pausa.
8. Si no hay más grupos, la jornada queda finalizada. Las fechas se interpretan en America/Bogota y los instantes se guardan en UTC.
9. Reintentos, doble toque o dos dispositivos simultáneos nunca deben activar dos grupos: bloqueo transaccional, versión del estado e identificador de operación para evitar duplicados.
10. El llamado inicial será visual dentro de la app. Sonido, notificaciones en segundo plano o una pantalla de altavoz se evaluarán aparte; no se presupone que todos tengan la app abierta.

## 4. Pantallas

- **Consulta de estudiante:** grupo activo, estado de la jornada, contador, siguiente grupo, agenda y última sincronización.
- **Acceso docente y administrador:** inicio y cierre de sesión, cambio de contraseña y errores claros.
- **Panel docente:** grupos asignados, turno activo y confirmación de «Finalizar atención».
- **Panel administrador:** jornada, programación, usuarios, grupos, asignaciones y acciones de control con confirmación.
- **Conexión y actualización:** aviso visible de desconexión, reintento y versión instalada.

Al perder conexión se muestra el último estado con su hora y una advertencia de que puede estar desactualizado. Las acciones de avance requieren conexión y confirmación del servidor; no se encolan automáticamente sin conexión.

## 5. Arquitectura propuesta

```text
App Android (Flutter) ── HTTPS ──> Proxy inverso ──> API Go ──> MySQL
                                      |
                         restaurante.in4.blue (implementado)

iecc.page.gd ── enlace de descarga ──> GitHub Releases ──> APK firmado
```

- **Flutter:** interfaz por rol, cliente HTTP, almacenamiento seguro de sesión y contador sincronizado con la hora del servidor.
- **Actualización del estado:** consulta periódica cada 5 segundos mientras la pantalla está visible; resincronización al volver a la app. Evaluar SSE si el piloto requiere menor latencia.
- **Go:** API JSON, validación, autenticación, autorización por recurso, motor de turnos, migraciones y auditoría.
- **MySQL:** base y usuario exclusivos de Protores, con permisos limitados. Flutter nunca se conecta directamente a MySQL.
- **Ubuntu:** API ejecutada con usuario de servicio sin privilegios, servicio systemd y proxy HTTPS compatible con la configuración existente.
- **Aislamiento:** subdominio, directorio, puerto local y base propios; inspeccionar el VPS antes de cambiar cualquier configuración de in4.blue.

## 6. Modelo de datos inicial

| Tabla | Contenido principal |
| --- | --- |
| users | Identificador, nombre, usuario, hash de contraseña, rol, estado y fechas. |
| school_groups | Grado, sección/grupo, jornada escolar y estado. |
| teacher_groups | Asignación de docentes a grupos. |
| service_days | Fecha, restaurante, estado de jornada, política de avance y versión. |
| turns | Jornada, grupo, orden, hora prevista, duración, estado, inicio y fin reales, tiempo pausado y docente responsable. |
| sessions | Sesiones o tokens de renovación revocables y vencimiento. |
| audit_events | Actor, acción, recurso, fecha, motivo y cambio registrado. |
| operations | Clave de operación, usuario, resultado y referencia para reintentos seguros. |

Definir claves foráneas, índices, unicidad del orden por jornada y estrategia transaccional que garantice un único turno activo. No se necesita almacenar nombres ni identificaciones de estudiantes para este alcance.

## 7. API inicial

Prefijo propuesto: `/api/v1`.

| Método y ruta | Acceso | Propósito |
| --- | --- | --- |
| POST /auth/login | Estudiante/docente/admin | Crear sesión. |
| POST /auth/refresh | Sesión válida | Renovar acceso. |
| POST /auth/logout | Sesión válida | Revocar sesión. |
| GET /me | Autenticado | Consultar identidad y permisos. |
| GET /status | Estudiante/docente/admin | Estado actual, hora del servidor, fin esperado y siguiente grupo, sin datos privados. |
| GET /schedule | Estudiante/docente/admin | Programación por fecha. |
| GET /teacher/turns | Docente | Consultar sus turnos. |
| POST /turns/{id}/finish | Docente asignado/admin | Finalizar y avanzar de forma atómica. |
| CRUD /admin/users | Admin | Gestionar docentes y administradores. |
| CRUD /admin/groups | Admin | Gestionar grupos y asignaciones. |
| GET/POST/PATCH /admin/service-days | Admin | Consultar, crear y editar jornadas. |
| POST /admin/service-days/{id}/start | Admin | Iniciar la jornada. |
| POST /admin/service-days/{id}/pause | Admin | Pausar atención. |
| POST /admin/service-days/{id}/resume | Admin | Reanudar atención. |
| POST /admin/turns/{id}/skip | Admin | Omitir turno con motivo. |
| POST /admin/turns/{id}/cancel | Admin | Cancelar turno con motivo. |
| GET /admin/audit | Admin | Consultar historial paginado. |
| GET /healthz | Monitorización | Comprobar disponibilidad sin revelar configuración. |

Documentar contratos en OpenAPI, fechas, paginación, códigos de error y conflictos de versión. Las rutas de consulta estudiantil solo devolverán la información necesaria para ese rol.

## 8. Fases y entregables

### Fase 0 — Confirmar operación y revisar lo existente

- [ ] Validar nombre oficial, grados, grupos, cantidad de docentes y responsables de administración.
- [ ] Revisar el PDF y los mockups presentes en el repositorio con la institución.
- [ ] Confirmar reglas de inicio, retrasos, pausas, avance temprano y acceso estudiantil.
- [x] Inventariar el VPS: servicios, proxy, dominios, puertos, recursos, MySQL y copias existentes.
- [ ] Confirmar acceso al DNS de in4.blue, al alojamiento de iecc.page.gd y al repositorio GitHub definitivo.
- [x] Corregir `go.mod` y verificar Go y dependencias; las pruebas se ejecutaron con caché de módulos aislada porque la caché previa contenía archivos vacíos.

**Entregable:** requisitos acordados, arquitectura e inventario de despliegue.

### Fase 1 — Base de datos y API

- [x] Crear estructura del servicio Go y configuración de ejemplo sin secretos.
- [x] Crear migraciones MySQL y datos ficticios de desarrollo.
- [x] Implementar sesiones, contraseñas con hash y permisos por rol y asignación.
- [x] Implementar creación de grupos, docentes, programación y motor transaccional de turnos.
- [ ] Añadir edición de grupos y de programaciones existentes; el MVP conserva una programación por fecha.
- [x] Implementar consulta de estado para los tres roles, auditoría y documentación OpenAPI.
- [x] Probar concurrencia, reintentos, recuperación tras reinicio y accesos no autorizados.

**Entregable:** API ejecutable localmente con MySQL y pruebas del flujo completo.

### Fase 2 — Aplicación Flutter Android

- [x] Crear proyecto en `mobile/`, identidad visual Protores y configuración por ambiente.
- [x] Implementar consulta de estudiante, sincronización y contador.
- [x] Implementar autenticación y panel docente con confirmación de finalización.
- [x] Implementar administración de jornadas, grupos y usuarios.
- [x] Manejar desconexión, conflictos de estado, sesión vencida y reintentos.
- [ ] Validar legibilidad, accesibilidad y funcionamiento en celulares Android físicos.

**Entregable:** APK de prueba con los tres perfiles de uso.

### Fase 3 — Despliegue en Ubuntu

- [x] Respaldar la configuración que vaya a modificarse y comprobar el estado de in4.blue.
- [x] Crear base y usuario MySQL exclusivos sin publicar el puerto de la base en Internet.
- [x] Instalar API como servicio, configurar secretos fuera del repositorio y restringir permisos.
- [x] Configurar DNS y HTTPS en el subdominio acordado.
- [x] Aplicar migraciones con respaldo y procedimiento de recuperación.
- [x] Configurar registros sin contraseñas ni tokens, rotación y copias de seguridad.
- [x] Probar restauración y acceso desde una red externa; verificar que in4.blue sigue funcionando.

**Entregable:** API disponible por HTTPS y procedimiento documentado de operación y reversión.

### Fase 4 — Distribución

- [x] Confirmar nombre del repositorio y paquete Android: existen referencias iniciales a «proteres», pero el producto solicitado es «Protores».
- [x] Configurar firma de producción y custodiar la clave fuera de Git; conservarla para futuras actualizaciones.
- [x] Publicar APK firmado, versión, notas y suma SHA-256 en GitHub Releases.
- [x] Crear página de descarga en `web/` y publicarla en iecc.page.gd con enlace HTTPS a la versión estable.
- [x] Explicar los pasos de instalación de un APK externo y mostrar versión y fecha.
- [ ] Probar descarga, instalación limpia y actualización conservando datos y sesión según la política acordada.

**Entregable:** descarga accesible desde iecc.page.gd y APK instalable.

### Fase 5 — Piloto y entrega

- [ ] Ejecutar una jornada simulada con administrador, dos docentes y consulta estudiantil.
- [ ] Ejecutar piloto en el restaurante y registrar incidencias.
- [ ] Ajustar tiempos y validar con los responsables de la institución.
- [ ] Entregar manual de administración, guía docente y procedimiento de soporte.
- [ ] Asignar responsables de usuarios, respaldos, actualizaciones y firma del APK.

**Entregable:** aceptación del flujo y puesta en uso.

## 9. Criterios de aceptación

- Un administrador programa una jornada y los usuarios visualizan la misma secuencia de grupos.
- Un docente solo finaliza el turno activo autorizado; estudiantes no pueden ejecutar escrituras, aunque llamen directamente a la API.
- Finalizar un turno activa exactamente el siguiente, incluso con doble toque o solicitudes concurrentes.
- El cambio aparece en los dispositivos conectados en un máximo objetivo de 10 segundos bajo las condiciones de red acordadas para el piloto.
- El contador se basa en el servidor, resiste cambios del reloj del celular y conserva correctamente las pausas y reinicios.
- El vencimiento del tiempo muestra cero y «tiempo excedido» hasta la finalización autorizada.
- La desconexión es visible y no permite presentar un avance local como confirmado.
- Los controles de inicio, pausa, reanudación, salto, cancelación y fin de jornada cumplen las reglas y dejan auditoría.
- El APK firmado se descarga desde iecc.page.gd, se instala y se actualiza con la misma firma.
- in4.blue mantiene su servicio existente después del despliegue y se demuestra la restauración de un respaldo de Protores.
- El repositorio, los logs y los artefactos publicados no contienen credenciales ni claves de firma.

## 10. Credenciales y operación

El acceso al VPS fue suministrado por separado; su contraseña no se copia a este documento ni al código. Cambiar la contraseña compartida y preparar acceso SSH por clave, conservando un acceso de recuperación comprobado. Usar la cuenta privilegiada solo para la preparación del servidor; ejecutar la API con usuario propio.

Guardar credenciales MySQL y secretos de sesión en configuración privada del servidor. Publicar únicamente `.env.example` con valores ficticios. Mantener el material de firma Android y sus copias de recuperación fuera del repositorio.

La conexión y los cambios reales del VPS, DNS, GitHub y alojamiento web se realizarán durante las fases correspondientes. Este documento no acredita que esos accesos o despliegues ya se hayan verificado.

## 11. Organización del repositorio

```text
mobile/                 App Flutter Android implementada
backend/                API Go y migraciones MySQL
deploy/                 Servicio systemd, proxy y guía de despliegue
scripts/                Automatización de desarrollo, respaldo y publicación
web/                    Página de descarga
docs/PLAN_DE_TRABAJO.md  Este plan y seguimiento
docs/                   Contratos, manuales y decisiones
```

Situación inicial: estructura mínima y archivos Go vacíos. Situación actual: API, tablas MySQL, app Flutter, servicio systemd, respaldos, documentación y pruebas implementados. El repositorio confirmado es `gutnarchois/protores`; el paquete Android es `co.edu.iecc.protores`.

## 12. Seguimiento

Actualizar las casillas cuando exista evidencia del entregable; registrar decisiones y bloqueos aquí.

| Hito | Dependencia | Responsable propuesto | Estado | Evidencia para cerrar |
| --- | --- | --- | --- | --- |
| Requisitos y revisión del servidor | Ninguna | Institución y desarrollo | Pendiente | Reglas acordadas e inventario técnico |
| API y MySQL | Requisitos | Desarrollo backend | Implementado | Migraciones y flujo de turnos probado |
| App Android | Contrato de API | Desarrollo Flutter | Implementada; APK pendiente | APK de prueba con los tres roles |
| API en producción | API validada e inventario | Operación del VPS | Desplegada | HTTPS, respaldo y restauración verificados |
| Descarga del APK | App validada y firma | Responsable de publicación | Pendiente | GitHub Release y enlace en iecc.page.gd |
| Piloto y entrega | App, API y descarga | Institución y desarrollo | Pendiente | Jornada aceptada y manuales entregados |

Los responsables son funciones propuestas, aún sin personas asignadas. Las fechas de entrega se fijarán después de revisar la disponibilidad del equipo y los accesos; el orden de las fases indica las dependencias, no un compromiso de calendario.

| Fecha | Avance o decisión | Próximo paso |
| --- | --- | --- |
| 2026-10-23 | Plan inicial creado a partir de la solicitud y la estructura local. | Validar operación escolar y revisar material de referencia; luego preparar API y migraciones. |

## 13. Registro de ejecución · 23 de octubre de 2026

- API instalada en `https://restaurante.in4.blue/api/v1`, servicio `protores`, puerto local 8091, MySQL con base y usuario propios. Se aprovechó el virtual host y el certificado existentes de restaurante.
- `/healthz`, login administrativo, consulta y logout verificados por HTTPS. `in4.blue` mantiene respuesta HTTP 200.
- Pruebas Go con detector de carreras y MySQL: 12 finalizaciones simultáneas producen un solo avance y una sola auditoría. Prueba HTTP completa con los tres roles, ocho reintentos simultáneos, pausa/reanudación y fin de jornada: aprobada.
- Flutter: análisis estático y prueba de pantalla inicial aprobados. APK firmado en compilación; la validación presencial sigue pendiente.
- Respaldo diario instalado y restauración comprobada en base temporal independiente; pendiente copia externa al VPS.
- Decisión de persistencia MVP: turnos en JSON dentro de la fila de jornada, protegida por bloqueo MySQL. No hay tablas separadas `turns` ni `operations`; la finalización repetida es segura por estado persistido. Ver `docs/API.md`.
- Sesiones de 12 horas con nuevo login al vencer; renovación de sesión queda fuera de esta versión.
- El usuario indicó que la publicación de `iecc.page.gd` será manual con él. Preparar ZIP estático e instrucciones; no se considera publicado hasta su comprobación.
- Credenciales y material de firma conservados en `.private/`, excluidos de Git. No se utilizaron ni cambiaron las contraseñas de otros servicios.

## Recuperación y publicación del repositorio · 23 de octubre de 2026

- Repositorio confirmado: `https://github.com/gutnarchois/protores`. Código publicado en `main`.
- Git local recuperado desde el repositorio remoto; metadatos dañados conservados fuera del proyecto en `/home/gutnar/protores-git-respaldo-q5REBG/`.
- Rutas del módulo Go y enlaces de descarga corregidos a `protores`.
- `flutter analyze` y `flutter test`: aprobados. `go test -race ./...` y `go vet ./...`: aprobados con caché aislada. Las pruebas MySQL de integración requieren una base desechable y no se repitieron en esta verificación.
- Compilación Android reintentada con caché Gradle aislada tras detectar corrupción de metadatos en la caché anterior.

## Distribución 0.1.0 · 23 de octubre de 2026

- Publicación: https://github.com/gutnarchois/protores/releases/tag/v0.1.0
- APK firmado: `protores-android.apk`, 51 477 864 bytes, Android 7.0 o superior, paquete `co.edu.iecc.protores`, versión `0.1.0`, código `1`. Firma de producción verificada con `apksigner`.
- SHA-256 APK: `a8d2e1e5bc03a4774907f35d2328e8fead2adaace9dd184f8e9e53868119b2c4`. Coincide con el digest del archivo publicado en GitHub. Enlace público de descarga comprobado: HTTP 200.
- `protores-web.zip` y `SHA256SUMS` incluidos en la versión. Página preparada para publicación manual con el usuario en iecc.page.gd.
- GitHub Actions: backend con MySQL y Flutter aprobados en la ejecución https://github.com/gutnarchois/protores/actions/runs/39966985407.
- Entorno local reparado: caché Go y Gradle aisladas, NDK, SDK Android 35 y CMake instalados, JDK 21 completo en `/home/gutnar/.local/share/protores-tools/jdk21`; Flutter configurado para ese JDK. Para recompilar localmente: `GOMODCACHE=/home/gutnar/.cache/protores-go` y `GRADLE_USER_HOME=/home/gutnar/.cache/protores-gradle-clean` según la herramienta.
- Pendiente: instalación y actualización en celulares físicos, publicación manual en iecc.page.gd y piloto institucional. No había dispositivos conectados para comprobar instalación.

## Publicación web · 23 de octubre de 2026

- Página publicada en https://iecc.page.gd/protores/ mediante FTPS.
- Portal existente conservado; añadido enlace «Protores · PAE» al menú principal.
- Archivos originales respaldados localmente en `.private/ftp-backup/`; credenciales fuera de Git.
- Contenido subido comprobado mediante descarga FTPS. Página pública verificada por HTTPS (HTTP 200 y contenido idéntico a `web/dist/index.html`) tras resolver la comprobación JavaScript del alojamiento.
- Pendientes: instalación y actualización en celulares físicos y piloto institucional.
