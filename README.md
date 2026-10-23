# Protores

Aplicación Android en Flutter para organizar los turnos del PAE de la Institución Educativa Cristóbal Colón, Mariano Ramos. API en Go y MySQL.

- **Administrador:** crea cuentas, grupos y estudiantes; programa fecha, hora, orden y duración; inicia, pausa, reanuda, omite y cancela turnos; registra y consulta asistencia por curso.
- **Docente:** finaliza el turno activo de su grupo para llamar al siguiente; registra ingresos por QR o búsqueda y consulta la asistencia de sus cursos.
- **Estudiante:** consulta el grupo actual, contador, siguiente grupo y programación. Sin permisos de escritura.

API desplegada: https://restaurante.in4.blue/api/v1 · [Estado del servicio](https://restaurante.in4.blue/healthz).

[Página de descarga](https://iecc.page.gd/protores/) · [Descargar APK](https://github.com/gutnarchois/protores/releases/latest) · [Plan de trabajo](docs/PLAN_DE_TRABAJO.md) · [Operación e instalación](docs/OPERACION.md) · [Contrato de API](docs/API.md).

## Desarrollo

Se necesitan Go 1.26 o superior, MySQL 8.4, Flutter 3.47.7, Java 21 y Android SDK 36. El proyecto Android se encuentra en `mobile/`.

```bash
cd backend
export MYSQL_DSN='protores:CLAVE_LOCAL@tcp(127.0.0.1:3306)/protores'
export ADMIN_USER=admin
export ADMIN_PASSWORD='UNA_CLAVE_LOCAL_DE_12_O_MAS_CARACTERES'
go run ./cmd/server bootstrap
go run ./cmd/server
```

Crear previamente la base y el usuario MySQL con acceso únicamente a esa base. El servicio instala las tablas iniciales al arrancar. No usar credenciales de producción en desarrollo.

```bash
cd mobile
flutter pub get
flutter analyze
flutter test
flutter run --dart-define=API_BASE_URL=https://restaurante.in4.blue/api/v1
```

Para un backend local en emulador Android se puede usar `http://10.0.2.2:8091/api/v1` con una configuración Android de **depuración** que permita HTTP. El manifiesto de producción exige HTTPS.

```bash
./scripts/test-backend.sh
# Integración de concurrencia: solo una base de pruebas desechable.
cd backend
TEST_MYSQL_DSN='usuario:clave@tcp(127.0.0.1:3306)/protores_test' go test -race ./...
```

La firma Android requiere `mobile/android/key.properties`, que está excluido de Git. Consultar la guía de operación. El repositorio es `gutnarchois/protores`; el producto y el paquete Android se llaman **Protores** y `co.edu.iecc.protores`.

Versión 0.2.0 para Android 7.0 o superior. Incorpora las cuatro pantallas del mockup, estudiantes por curso, registro de asistencia por QR o búsqueda y resumen de asistencia. API y página de descarga actualizadas. Versión para piloto: falta la validación presencial de la institución y del escáner en dispositivos físicos. No incluye inventario de alimentos.
