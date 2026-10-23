# Publicación manual en iecc.page.gd

1. Descargar `protores-web.zip` desde la versión de GitHub Releases o tomar `web/dist/index.html` de este repositorio.
2. Entrar al administrador de archivos del alojamiento de **iecc.page.gd**.
3. Identificar la carpeta pública de ese dominio (normalmente `htdocs` o `public_html`; verificarla en el panel).
4. Si existe una página principal, descargar una copia antes de reemplazarla. Para conservar el sitio actual, crear una carpeta `protores/` y colocar allí el archivo.
5. Extraer el ZIP y subir `index.html` a la carpeta elegida. El ZIP no debe quedar como una carpeta adicional que impida encontrar `index.html`.
6. Abrir `https://iecc.page.gd/` o `https://iecc.page.gd/protores/`, según la ubicación escogida.
7. Pulsar **Descargar para Android** desde un celular y comprobar la instalación.

La página es estática y no necesita PHP, MySQL ni credenciales de la API. La app se conecta por HTTPS al VPS, y el APK se descarga desde GitHub. No subir `.private`, archivos `.env`, claves SSH ni la clave de firma al alojamiento.

Enlace directo estable al APK:

https://github.com/gutnarchois/protores/releases/latest/download/protores-android.apk

Si el alojamiento no permite HTTPS, activarlo desde su panel y verificar el certificado antes de anunciar la dirección a la comunidad.
