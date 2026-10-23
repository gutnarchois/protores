# Plan de trabajo — Protores

Fecha de elaboración: 23 de octubre de 2026.
Institución: Institución Educativa Cristóbal Colón, sede Mariano Ramos (nombre oficial por confirmar).
Última actualización: 23 de octubre de 2026.

Estado: MVP implementado; API desplegada; APK firmado 0.1.0 y página de descarga publicados y verificados. Pendientes: validación en celulares físicos, acuerdos operativos y piloto institucional.

- [API de producción](https://restaurante.in4.blue/api/v1) · [Salud del servicio](https://restaurante.in4.blue/healthz).
- [Página de descarga](https://iecc.page.gd/protores/) · [Versión 0.1.0 y SHA-256](https://github.com/gutnarchois/protores/releases/tag/v0.1.0).
- [Repositorio](https://github.com/gutnarchois/protores) · [Comprobaciones aprobadas](https://github.com/gutnarchois/protores/actions/runs/39966985407).

## 1. Objetivo

Crear una aplicación Android en Flutter para organizar la atención del Programa de Alimentación Escolar (PAE) por grado y grupo. El administrador configura los horarios; los docentes informan cuando termina la atención de su grupo; los estudiantes consultan quién está en el restaurante, cuánto tiempo queda y quién sigue.

La aplicación consume una API en Go con MySQL, alojada en el VPS Ubuntu asociado a in4.blue. El APK firmado está publicado en GitHub Releases y se ofrece desde https://iecc.page.gd/protores/.

## 2. Alcance de la primera versión

| Rol | Funciones |
| --- | --- |
| Administrador | Crear y desactivar usuarios docentes, registrar grados y grupos, asignar docentes, configurar horarios y duración, ordenar turnos, iniciar o pausar la jornada, reanudar, saltar o cancelar un turno y consultar el historial. |
| Docente | Iniciar sesión, consultar sus grupos y turnos, ver el estado general y marcar como finalizado únicamente el turno activo que tenga asignado. |
| Estudiante | Consultar el grupo actual, tiempo restante, siguiente grupo y programación del día; sin permisos de modificación. |

El MVP implementa los tres roles solicitados: administrador, docente y estudiante. El estudiante inicia sesión y tiene permisos de solo lectura, sin acceso a usuarios, asignaciones ni auditoría. Para minimizar datos personales, se definirá con la institución el mecanismo de alta y acceso estudiantil. Una consulta pública sin cuenta será opcional y deberá acordarse antes de habilitarla.

Fuera del MVP: inventario de alimentos, registro individual de consumo, biometría, información nutricional y múltiples restaurantes simultáneos.

## 3. Reglas de los turnos

1. El administrador configura una jornada con fecha, hora de inicio, grupos, orden y duración por turno; no se permiten posiciones duplicadas ni horarios incompatibles.
2. Solo puede existir un turno activo por jornada y restaurante. El administrador inicia la atención; hasta entonces se muestra «pendiente de inicio».
3. Al finalizar su atención, el docente confirma una vez. La API registra quién finalizó, cierra el turno y activa el siguiente en una sola transacción.
4. El horario es una referencia de planificación. La duración real se cuenta desde la activación del turno; finalizar temprano adelanta el siguiente. La versión 0.1.0 no espera hasta la hora programada para activar al siguiente; cualquier cambio de esta política requiere acuerdo institucional y una nueva implementación.
5. Llegar a cero muestra «tiempo excedido» y el contador restante se queda en cero. Por defecto no se avanza automáticamente: la confirmación del docente evita llamar a otro grupo mientras el restaurante sigue ocupado.
6. El administrador puede finalizar, omitir o cancelar turnos. Omitir y cancelar requieren un motivo obligatorio. Los cambios quedan registrados en auditoría.
7. Pausar congela el contador y bloquea el avance habitual; reanudar conserva el tiempo restante. El servidor conserva los instantes y duración acumulada de pausa.
8. Si no hay más grupos, la jornada queda finalizada. Las fechas se interpretan en America/Bogota y los instantes se guardan en UTC.
9. Reintentos, doble toque o dos dispositivos simultáneos nunca deben activar dos grupos: bloqueo transaccional, versión del estado y comprobación del turno persistido. La versión 0.1.0 no implementa identificadores de operación independientes.
10. El llamado es visual dentro de la app. Sonido, notificaciones en segundo plano o una pantalla de altavoz se evaluarán aparte; no se presupone que todos tengan la app abierta.

## 4. Pantallas

- **Consulta de estudiante:** grupo activo, estado de la jornada, contador, siguiente grupo, agenda y última sincronización.
- **Acceso docente y administrador:** inicio y cierre de sesión, cambio de contraseña y errores claros.
- **Panel docente:** grupos asignados, turno activo y confirmación de «Finalizar atención».
- **Panel administrador:** jornada, programación, usuarios, grupos, asignaciones y acciones de control con confirmación.
- **Conexión y actualización:** aviso visible de desconexión, reintento y versión instalada.

Al perder conexión se muestra el último estado con su hora y una advertencia de que puede estar desactualizado. Las acciones de avance requieren conexión y confirmación del servidor; no se encolan automáticamente sin conexión.

## 5. Arquitectura implementada

```text
App Android (Flutter) ── HTTPS ──> Proxy inverso ──> API Go ──> MySQL
                                      |
                         restaurante.in4.blue (implementado)

iecc.page.gd/protores/ ── enlace de descarga ──> GitHub Releases ──> APK firmado
```

- **Flutter:** interfaz por rol, cliente HTTP, almacenamiento seguro de sesión y contador sincronizado con la hora del servidor.
- **Actualización del estado:** consulta periódica cada 5 segundos mientras la pantalla está visible; resincronización al volver a la app. Evaluar SSE si el piloto requiere menor latencia.
- **Go:** API JSON, validación, autenticación, autorización por recurso, motor de turnos, migraciones y auditoría.
- **MySQL:** base y usuario exclusivos de Protores, con permisos limitados. Flutter nunca se conecta directamente a MySQL.
- **Ubuntu:** API ejecutada con usuario de servicio sin privilegios, servicio systemd y proxy HTTPS compatible con la configuración existente.
- **Aislamiento:** subdominio, directorio, puerto local y base propios; inspeccionar el VPS antes de cambiar cualquier configuración de in4.blue.

## 6. Modelo de datos implementado

| Tabla | Contenido principal |
| --- | --- |
| users | Nombre, usuario, hash de contraseña, rol, estado y fecha de creación. |
| sessions | Hash del token, usuario y vencimiento; sesiones revocables de 12 horas. |
| school_groups | Nombre del grupo, docente asignado y estado. |
| service_days | Fecha única, versión y estado JSON con programación, turnos y pausas. |
| audit_events | Actor, acción, recurso, detalle JSON y fecha. |

Los turnos se guardan en `service_days.state`. El bloqueo de esa fila en una transacción MySQL permite guardar el avance y su auditoría juntos. Las finalizaciones repetidas consultan el estado persistido y no activan otro grupo. No hay tablas independientes `teacher_groups`, `turns` ni `operations`; las asignaciones se copian a la programación para conservar su historial. No se necesita almacenar identificaciones de estudiantes.

Referencia: `backend/internal/app/schema.sql` y [API.md](API.md).

## 7. API implementada

Base: `https://restaurante.in4.blue/api/v1`. La comprobación de salud está fuera del prefijo: `/healthz`.

| Método y ruta | Acceso | Propósito |
| --- | --- | --- |
| POST /auth/login | Estudiante/docente/admin | Crear sesión de 12 horas. |
| POST /auth/logout | Autenticado | Revocar sesión. |
| POST /auth/password | Autenticado | Cambiar contraseña y revocar las otras sesiones. |
| GET /me | Autenticado | Consultar identidad y permisos. |
| GET /status y /schedule | Estudiante/docente/admin | Consultar estado y programación por fecha. |
| GET /teacher/turns | Docente | Consultar sus turnos. |
| POST /turns/{id}/finish | Docente asignado/admin | Finalizar y avanzar de forma atómica. |
| GET/POST /admin/users | Admin | Consultar y crear usuarios. |
| PATCH /admin/users/{id} | Admin | Activar/desactivar y restablecer contraseña. |
| GET/POST /admin/groups | Admin | Consultar y crear grupos con docente asignado. |
| POST /admin/service-days | Admin | Crear una programación por fecha. |
| POST /admin/service-days/{id}/start | Admin | Iniciar la jornada. |
| POST /admin/service-days/{id}/pause | Admin | Pausar atención. |
| POST /admin/service-days/{id}/resume | Admin | Reanudar atención. |
| POST /admin/turns/{id}/skip | Admin | Omitir turno con motivo. |
| POST /admin/turns/{id}/cancel | Admin | Cancelar turno con motivo. |
| GET /admin/audit | Admin | Consultar las últimas 100 acciones. |
| GET /healthz | Monitorización | Comprobar disponibilidad. |

Contratos y errores documentados en [API.md](API.md) y [openapi.json](openapi.json). No se implementó `/auth/refresh`: al vencer la sesión se inicia sesión nuevamente. La edición de grupos y programaciones existentes queda pendiente. Los identificadores de turno son locales a la jornada y las acciones incluyen fecha y versión.

## 8. Fases y entregables

### Fase 0 — Confirmar operación y revisar lo existente

- [ ] Validar nombre oficial, grados, grupos, cantidad de docentes y responsables de administración.
- [ ] Revisar el PDF y los mockups presentes en el repositorio con la institución.
- [ ] Confirmar reglas de inicio, retrasos, pausas, avance temprano y acceso estudiantil.
- [x] Inventariar el VPS: servicios, proxy, dominios, puertos, recursos, MySQL y copias existentes.
- [x] Confirmar repositorio GitHub definitivo y acceso de publicación: `gutnarchois/protores`.
- [x] Confirmar acceso FTPS al alojamiento de iecc.page.gd y publicar en `/protores/`.
- [ ] Confirmar acceso administrativo al DNS de in4.blue para futuros cambios; el subdominio y HTTPS existentes ya funcionan.
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

**Entregable:** APK firmado 0.1.0 publicado con los tres perfiles; validación física pendiente.

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

- [x] Confirmar repositorio `gutnarchois/protores`, producto Protores y paquete Android `co.edu.iecc.protores`.
- [x] Configurar firma de producción y custodiar la clave fuera de Git; conservarla para futuras actualizaciones.
- [x] Publicar APK firmado, versión, notas y suma SHA-256 en GitHub Releases.
- [x] Crear página de descarga en `web/` y publicarla en iecc.page.gd con enlace HTTPS a la versión estable.
- [x] Explicar los pasos de instalación de un APK externo y mostrar versión y fecha.
- [x] Verificar firma del APK, SHA-256 publicado y enlace público de descarga (HTTP 200).
- [x] Publicar en `/protores/`, añadir enlace al portal principal y respaldar sus archivos originales.
- [ ] Probar descarga desde celular, instalación limpia y actualización conservando datos y sesión según la política acordada.

**Entregable:** página y APK firmado publicados; instalación y actualización en celulares pendientes de comprobar.

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

La API, GitHub Releases y el alojamiento web ya se utilizaron y verificaron según los registros de ejecución. El acceso administrativo al DNS para cambios futuros continúa pendiente de confirmar. Las credenciales FTPS y los respaldos del portal se conservan en `.private/`, excluido de Git.

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

| Hito | Dependencia | Responsable propuesto | Estado | Evidencia o pendiente |
| --- | --- | --- | --- | --- |
| Requisitos y revisión del servidor | Ninguna | Institución y desarrollo | Parcial | Inventario técnico realizado; faltan acuerdos y revisión institucional |
| API y MySQL | Requisitos | Desarrollo backend | Implementado | Migraciones y flujo de turnos probado |
| App Android | Contrato de API | Desarrollo Flutter | APK 0.1.0 publicado | Análisis, prueba Flutter y firma aprobados; falta validación en celulares |
| API en producción | API validada e inventario | Operación del VPS | Desplegada | HTTPS, respaldo y restauración verificados |
| Descarga del APK | App y firma | Responsable de publicación | Publicada y verificada | Release 0.1.0 y página HTTPS en iecc.page.gd/protores/; falta instalación física |
| Piloto y entrega | App, API y descarga | Institución y desarrollo | Pendiente | Jornada aceptada y manuales entregados |

Los responsables son funciones propuestas, aún sin personas asignadas. Las fechas de entrega se fijarán después de revisar la disponibilidad del equipo y los accesos; el orden de las fases indica las dependencias, no un compromiso de calendario.

| Fecha | Avance o decisión | Próximo paso |
| --- | --- | --- |
| 2026-10-23 | MVP, API y respaldos implementados; pruebas de backend con MySQL y Flutter aprobadas. | Confirmar reglas y responsables con la institución. |
| 2026-10-23 | Git recuperado, código publicado y APK 0.1.0 firmado disponible con SHA-256. | Descargar e instalar en celulares físicos. |
| 2026-10-23 | Página publicada en iecc.page.gd/protores/ y enlazada desde el portal existente. | Ejecutar jornada simulada y piloto institucional. |

## 13. Registro de ejecución · 23 de octubre de 2026

- API instalada en `https://restaurante.in4.blue/api/v1`, servicio `protores`, puerto local 8091, MySQL con base y usuario propios. Se aprovechó el virtual host y el certificado existentes de restaurante.
- `/healthz`, login administrativo, consulta y logout verificados por HTTPS. `in4.blue` mantiene respuesta HTTP 200.
- Pruebas Go con detector de carreras y MySQL: 12 finalizaciones simultáneas producen un solo avance y una sola auditoría. Prueba HTTP completa con los tres roles, ocho reintentos simultáneos, pausa/reanudación y fin de jornada: aprobada.
- Flutter: análisis estático y prueba de pantalla inicial aprobados. APK firmado 0.1.0 compilado y publicado; la validación presencial sigue pendiente.
- Respaldo diario instalado y restauración comprobada en base temporal independiente; pendiente copia externa al VPS.
- Decisión de persistencia MVP: turnos en JSON dentro de la fila de jornada, protegida por bloqueo MySQL. No hay tablas separadas `turns` ni `operations`; la finalización repetida es segura por estado persistido. Ver `docs/API.md`.
- Sesiones de 12 horas con nuevo login al vencer; renovación de sesión queda fuera de esta versión.
- La publicación web inicialmente prevista como manual se completó después con las credenciales FTPS suministradas por el usuario: `/protores/` está publicado y verificado.
- Credenciales y material de firma conservados en `.private/`, excluidos de Git. No se utilizaron ni cambiaron las contraseñas de otros servicios.

## 14. Recuperación y publicación del repositorio · 23 de octubre de 2026

- Repositorio confirmado: `https://github.com/gutnarchois/protores`. Código publicado en `main`.
- Git local recuperado desde el repositorio remoto; metadatos dañados conservados fuera del proyecto en `/home/gutnar/protores-git-respaldo-q5REBG/`.
- Rutas del módulo Go y enlaces de descarga corregidos a `protores`.
- `flutter analyze` y `flutter test`: aprobados. `go test -race ./...` y `go vet ./...`: aprobados con caché aislada. Las pruebas MySQL no se repitieron localmente; sí se ejecutaron y aprobaron en GitHub Actions con una base desechable.
- Compilación Android reintentada con caché Gradle aislada tras detectar corrupción de metadatos en la caché anterior.

## 15. Distribución 0.1.0 · 23 de octubre de 2026

- Publicación: https://github.com/gutnarchois/protores/releases/tag/v0.1.0
- APK firmado: `protores-android.apk`, 51 477 864 bytes, Android 7.0 o superior, paquete `co.edu.iecc.protores`, versión `0.1.0`, código `1`. Firma de producción verificada con `apksigner`.
- SHA-256 APK: `a8d2e1e5bc03a4774907f35d2328e8fead2adaace9dd184f8e9e53868119b2c4`. Coincide con el digest del archivo publicado en GitHub. Enlace público de descarga comprobado: HTTP 200.
- `protores-web.zip` y `SHA256SUMS` incluidos en la versión. Página publicada y verificada en https://iecc.page.gd/protores/.
- GitHub Actions: backend con MySQL y Flutter aprobados en la ejecución https://github.com/gutnarchois/protores/actions/runs/39966985407.
- Entorno local reparado: caché Go y Gradle aisladas, NDK, SDK Android 35 y CMake instalados, JDK 21 completo en `/home/gutnar/.local/share/protores-tools/jdk21`; Flutter configurado para ese JDK. Para recompilar localmente: `GOMODCACHE=/home/gutnar/.cache/protores-go` y `GRADLE_USER_HOME=/home/gutnar/.cache/protores-gradle-clean` según la herramienta.
- Pendiente: instalación y actualización en celulares físicos y piloto institucional. No había dispositivos conectados para comprobar instalación.

## 16. Publicación web · 23 de octubre de 2026

- Página publicada en https://iecc.page.gd/protores/ mediante FTPS.
- Portal existente conservado; añadido enlace «Protores · PAE» al menú principal.
- Archivos originales respaldados localmente en `.private/ftp-backup/`; credenciales fuera de Git.
- Contenido subido comprobado mediante descarga FTPS. Página pública verificada por HTTPS (HTTP 200 y contenido idéntico a `web/dist/index.html`) tras resolver la comprobación JavaScript del alojamiento.
- Pendientes: instalación y actualización en celulares físicos y piloto institucional.

## 17. Próximos pasos y pendientes reales

1. Confirmar nombre oficial, grupos, docentes, responsables y mecanismo de acceso estudiantil; revisar PDF y mockups con la institución.
2. Descargar el APK en celulares Android 7 o superiores, comprobar instalación limpia, legibilidad, accesibilidad, reconexión y uso de los tres roles.
3. Comprobar actualización con la misma firma, conservación de datos y comportamiento de la sesión.
4. Ejecutar una jornada simulada presencial con administrador, dos docentes y estudiantes; comprobar pausas, avance temprano, vencimiento y sincronización entre dispositivos. Las pruebas automatizadas ya realizadas no sustituyen esta validación.
5. Realizar el piloto en el restaurante, registrar incidencias y ajustar tiempos con los responsables.
6. Entregar las guías de administración, docencia y soporte; asignar responsables de cuentas, copias, firma y actualizaciones. Implementar copia de respaldo externa al VPS y confirmar acceso administrativo al DNS.
7. Programar la siguiente iteración para editar grupos y jornadas existentes. La renovación de sesión, notificaciones y otros cambios de alcance requieren priorización aparte.

La publicación técnica está completada. La aceptación institucional y la puesta en uso siguen pendientes; no se fija una fecha sin acordarla con la institución.
