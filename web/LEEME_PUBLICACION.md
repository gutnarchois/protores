# Publicación manual en iecc.page.gd

1. Descargar `protores-web.zip` desde la versión de GitHub Releases o tomar todo el contenido de `web/dist/` de este repositorio.
2. Entrar al administrador de archivos del alojamiento de **iecc.page.gd**.
3. Identificar la carpeta pública de ese dominio (normalmente `htdocs` o `public_html`; verificarla en el panel).
4. Si existe una página principal, descargar una copia antes de reemplazarla. Para conservar el sitio actual, crear una carpeta `protores/` y colocar allí `index.html` y la carpeta `assets/`.
5. Extraer el ZIP y subir `index.html` y la carpeta `assets/` completa a la carpeta elegida. El ZIP no debe quedar como una carpeta adicional que impida encontrar `index.html`.
6. Abrir `https://iecc.page.gd/` o `https://iecc.page.gd/protores/`, según la ubicación escogida.
7. Pulsar **Descargar para Android** desde un celular y comprobar la instalación.

La página es estática y no necesita PHP, MySQL ni credenciales de la API. La app se conecta por HTTPS al VPS, y el APK se descarga desde GitHub. No subir `.private`, archivos `.env`, claves SSH ni la clave de firma al alojamiento.

Enlace directo estable al APK:

https://github.com/gutnarchois/protores/releases/latest/download/protores-android.apk

Si el alojamiento no permite HTTPS, activarlo desde su panel y verificar el certificado antes de anunciar la dirección a la comunidad.

## Publicación vigente

La versión 0.3.0 está publicada en https://iecc.page.gd/protores/ y enlazada desde el portal principal. Incluye horarios editables, logo propio e ilustración del restaurante. El botón usa el enlace estable al APK firmado de GitHub Releases.

Comprobar por HTTPS la versión de la página, ambas imágenes y el botón. Si la codificación de los PNG cambia en el alojamiento, comprobar también dimensiones y contenido visual decodificado; el APK debe coincidir exactamente con el SHA-256 de `SHA256SUMS`.
