# Replicarm Renombrados
Script sencillo para copiar cambios de nombre de ficheros entre carpetas.

Cuando tienes copias de seguridad repetidas en varios directorios en diferentes dispositivos, las herramientas para sincronizar esas copias de seguridad suelen identificar los ficheros renombrados como nuevos. Eso provoca que eliminen, copien o creen nuevos ficheros entre dispositivos en las sincronizaciones, lo cual es lento y poco eficiente.

Este script busca que ficheros son diferentes entre carpetas, hace una comparación rápida para buscar cuales tienen el mismo tamaño, calcula un checksum de esos ficheros nuevos que coinciden en tamaño para asegurarse de que son el mismo y renombra los ficheros necesarios.
