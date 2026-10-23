# Operación de Protores

## Instalación verificada

- API: `https://restaurante.in4.blue/api/v1`.
- Salud: `https://restaurante.in4.blue/healthz`.
- Servicio: `protores.service`, usuario Linux `protores`, binario `/opt/protores/protores-api`.
- Escucha: `127.0.0.1:8091`, Apache publica únicamente las rutas de API y salud en el virtual host existente de restaurante.
- Base: `protores`; usuario exclusivo con permisos sobre esa base. Puerto MySQL local.
- Configuración privada: `/etc/protores.env`, permisos 600. No incluirla en Git.
- Repositorio: `https://github.com/gutnarchois/protores`.

El acceso administrativo inicial está en `.private/ACCESO_ADMIN.md` en el equipo de trabajo y no se publica. Ingresar y cambiar la contraseña con el icono de candado antes del piloto. No se crearon docentes ni estudiantes ficticios en producción.

## Primera jornada

1. Instalar el APK firmado. Abrir Protores e ingresar como administrador.
2. En **Administrar**, crear docentes y cuentas estudiantiles de solo lectura.
3. Crear los grupos, indicando su docente responsable.
4. Programar la fecha y seleccionar los grupos **en orden de atención**; indicar hora de inicio y minutos por grupo.
5. El día del servicio, pulsar **Iniciar jornada** desde Turnos. El primer grupo aparece en el restaurante.
6. El docente asignado confirma **Finalizar atención y llamar al siguiente** al salir su grupo.
7. Los estudiantes ven el cambio en hasta unos cinco segundos bajo conectividad normal.
8. El administrador puede pausar/reanudar, omitir o cancelar con motivo. El historial registra las acciones.

El tiempo vencido no activa otro grupo automáticamente. Al perder red, el estado se señala como desactualizado y los botones de avance se deshabilitan tras detectar la desconexión. La API siempre decide si un cambio se confirmó.

La primera versión aún no permite editar una programación creada: revisarla antes de guardar. No registrar estudiantes por nombre si la institución puede asignar identificadores de cuenta que reduzcan datos personales.

## Supervisión y respaldo

```bash
systemctl status protores
journalctl -u protores --since today
curl -fsS https://restaurante.in4.blue/healthz
/usr/local/sbin/protores-backup
```

La tarea `/etc/cron.d/protores-backup` realiza respaldo diario a las 02:23 **UTC del VPS** (21:23 de Colombia del día anterior). Conserva 14 días en `/var/backups/protores`, con acceso root. Incluye volcado consistente MySQL y configuración/binario del servicio. La restauración se verificó en una base temporal separada; se eliminó después de la prueba. Las copias siguen en el mismo VPS: acordar una segunda ubicación externa para recuperación ante pérdida del servidor.

Para restaurar, detener la API, guardar primero una copia del estado actual y cargar el SQL elegido en la base `protores` usando credenciales locales de administración. Validar usuarios/jornadas y reiniciar. No restaurar otros servicios ni otras bases.

## Actualizar API

1. Ejecutar pruebas Go y pruebas de integración en una base desechable.
2. Compilar: `CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -o bin/protores-api ./cmd/server` desde `backend/`.
3. Ejecutar respaldo en el VPS y cargar el binario nuevo como archivo temporal.
4. Instalar con propietario root, grupo protores y permisos 750; reiniciar `protores`.
5. Comprobar `/healthz`, login, consulta y `https://in4.blue`. Si falla, recuperar el binario previo del respaldo y reiniciar.

La instalación inicial se conserva en `deploy/install-server.sh`; no ejecutarla sobre una instalación existente. Las migraciones iniciales usan `CREATE TABLE IF NOT EXISTS`; cambios futuros de esquema necesitan migraciones explícitas y respaldo.

## APK y firma

Identificador Android: `co.edu.iecc.protores`. La versión está en `mobile/pubspec.yaml` y debe aumentar en cada publicación. Android exige la misma firma para actualizar.

La clave y su contraseña están en `.private/protores-release.jks` y `.private/android-signing-password`; `mobile/android/key.properties` apunta a ellas. Guardar una copia cifrada bajo custodia de la institución. Ninguno de esos archivos va a GitHub.

Formato local de `mobile/android/key.properties`:

```properties
storeFile=/RUTA/PRIVADA/protores-release.jks
storePassword=SECRETO
keyPassword=SECRETO
keyAlias=protores
```

```bash
cd mobile
flutter analyze
flutter test
flutter build apk --release
```

Publicar el APK como `protores-android.apk`, su SHA-256 y las notas en GitHub Releases. El enlace estable de descarga será `https://github.com/gutnarchois/protores/releases/latest/download/protores-android.apk`.

En Android, autorizar la instalación desde la aplicación usada para descargar el APK, instalar y luego desactivar ese permiso si se desea. La primera publicación es para piloto, pendiente de validación presencial con docentes y estudiantes.

## iecc.page.gd

El dominio no respondió por HTTP/HTTPS durante la implementación. El usuario realizará la publicación manualmente. El ZIP y `web/LEEME_PUBLICACION.md` contienen la página y los pasos; la publicación allí sigue pendiente. La distribución por GitHub Releases funciona independientemente de ese alojamiento; se puede añadir allí el enlace estable al APK cuando esté disponible el acceso.


Actualización del 23 de octubre de 2026: la página ya está publicada en https://iecc.page.gd/protores/ y enlazada desde el portal principal. El alojamiento requiere JavaScript para su comprobación de navegador. Se conservó el portal existente y se respaldaron sus archivos en `.private/ftp-backup/`.
