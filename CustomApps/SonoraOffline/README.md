# Sonora para iPhone

App nativa para abrir enlaces públicos de canciones o álbumes de Spotify, encontrar una coincidencia en YouTube y guardar el audio en el propio iPhone. No necesita un PC ni un servidor para descargar o reproducir.

## Uso

1. Instala `Sonora-1.0.0.ipa` con iloader.
2. Copia un enlace de canción o álbum desde Spotify y pégalo en Sonora.
3. Pulsa **Abrir canción o álbum**, y después la flecha de descarga de una canción o **Descargar álbum**.
4. Las canciones terminadas aparecen en **En mi iPhone**. Desde ahí se reproducen sin conexión, también con la pantalla bloqueada.

El menú de una canción permite elegir manualmente otra coincidencia de YouTube. Las descargas se guardan en `Archivos > En mi iPhone > Sonora > Audio` y también pueden compartirse desde la biblioteca.

## Alcance

- El audio proviene de YouTube/YouTube Music; Spotify aporta la identificación y los metadatos. No se utiliza el audio de las previsualizaciones de Spotify.
- La extracción utiliza YouTubeKit 0.4.10, exclusivamente en modo local. El servidor alternativo de esa biblioteca está deshabilitado.
- No se requieren una cuenta de Spotify ni claves API para importar enlaces públicos.
- Los cambios de YouTube, las restricciones de una grabación y la región pueden impedir algunas descargas. Los errores aparecen por canción y permiten reintentar o seleccionar otra coincidencia.
- Esta primera versión abre enlaces; no es una modificación del botón de descarga de la app oficial de Spotify.
- Usa las descargas únicamente cuando tengas permiso para guardar el contenido.

## Compilar

Requiere macOS con Xcode 26.1.1 y XcodeGen. También se puede ejecutar el flujo `Build Sonora for iPhone` desde GitHub Actions.

```sh
swift test
swift GenerateIcon.swift
xcodegen generate
xcodebuild -project Sonora.xcodeproj -scheme Sonora -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
mkdir -p output/Payload
cp -R build/Build/Products/Release-iphoneos/Sonora.app output/Payload/
cd output && zip -qry Sonora-1.0.0.ipa Payload
```

El flujo conserva un diagnóstico de red aparte de las pruebas. Ese diagnóstico usa una muestra pequeña del audio de Big Buck Bunny (Blender Foundation, Creative Commons); los servidores de compilación pueden recibir restricciones distintas a las del iPhone.

## Dependencia

[YouTubeKit](https://github.com/alexeichhorn/YouTubeKit), MIT, Alexander Eichhorn y colaboradores. Se incluye la licencia con el código fuente.
