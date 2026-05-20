# Sharing Wi-Fi to Ethernet Tool

**Creado por:** Richard Campos - PMO

---

## 📌 Descripción del Proyecto

Esta es una herramienta interactiva para Windows diseñada para simplificar el proceso de compartir la conexión a Internet. Detecta automáticamente la conexión Wi-Fi actual de la laptop y comparte su acceso a internet a través del puerto Ethernet físico. Es ideal para conectar dispositivos o routers repetidores que no cuentan con acceso inalámbrico directo, proporcionándoles internet mediante un cable de red (RJ45).

La herramienta está compuesta por un **lanzador Batch (.bat)** que gestiona la experiencia de un solo clic y un **motor lógico en PowerShell (.ps1)** que se encarga de la interacción con las redes de Windows y el Internet Connection Sharing (ICS).

## 🚀 Características Principales

1. **Despliegue de un Solo Clic:** Toda la lógica inicia ejecutando un sencillo archivo `.bat`.
2. **Auto-Elevación de Privilegios:** El script solicita automáticamente los permisos de Administrador necesarios sin requerir que el usuario haga clic derecho > "Ejecutar como administrador".
3. **Detección Dinámica e Inteligente:** Identifica automáticamente cuál es el adaptador Wi-Fi que tiene acceso a internet y cuál es la interfaz Ethernet local, sin depender de nombres fijos (hardcoded) como "Wi-Fi" o "Ethernet 2".
4. **Menú Interactivo y Persistente:** Una interfaz de consola amigable con colores (ANSI) que se mantiene viva mostrando opciones claras para iniciar, ver el estado, detener la red y salir.
5. **Cierre Seguro (Safe Shutdown):** Un manejo de estado robusto que asegura que, al salir o presionar Ctrl+C, los adaptadores de red regresan a su estado original, previniendo fallos en la conexión Wi-Fi posterior. *Nota: La herramienta detecta si fue ella misma quien activó el ICS para no interferir con configuraciones previas del usuario.*
6. **Manejo de Errores Claro:** Notificaciones precisas si el Wi-Fi no tiene internet o si el cable Ethernet se encuentra desconectado.
7. **Monitor de Red en Vivo:** Visualización en tiempo real de la velocidad de subida (TX) y bajada (RX) nativa del adaptador Ethernet.
8. **Consumo Acumulado (GB):** Muestra el total acumulado en gigabytes (GB) de bajada y subida transferidos durante el período de monitorización activa de la sesión.
9. **Registro Histórico de Consumo:** Guarda automáticamente los registros detallados de velocidad y fecha en el archivo local `NetworkUsageLog.txt`, y cuenta con un visor interactivo integrado en el menú principal para consultar el historial sin salir de la herramienta.

## 🛠️ Arquitectura y Tecnologías

- **`SharingWiFiToEthernet.bat`**: Archivo lanzador. Contiene la lógica para la auto-elevación y la invocación del motor con las políticas de ejecución correctas.
- **`Engine_ICS.ps1`**: Motor lógico principal escrito en PowerShell 5.1 (Compatible nativamente con Windows 10 y 11). Utiliza el objeto COM `HNetCfg.HNetShare` para gestionar la Conexión Compartida a Internet a bajo nivel y el cmdlet `Get-NetAdapterStatistics` para medir el tráfico.

## 📋 Requisitos Previos

- Sistema Operativo: **Windows 10 o Windows 11**.
- Conexión a Internet activa a través del adaptador **Wi-Fi**.
- Un cable **Ethernet (RJ45)** conectado entre la laptop y el dispositivo receptor (ej. router repetidor).
- El servicio de Windows "Conexión compartida a Internet (ICS)" (`SharedAccess`) debe estar habilitado en el sistema (usualmente lo está por defecto).

## 📖 Paso a Paso: Cómo usar la herramienta

1. **Preparación Física:** Asegúrate de que tu laptop esté conectada al Wi-Fi con internet y conecta el cable de red desde el puerto Ethernet de la laptop al puerto WAN/LAN del router repetidor o dispositivo.
2. **Ejecutar el Lanzador:** En esta carpeta, haz doble clic sobre el archivo **`SharingWiFiToEthernet.bat`**.
3. **Aceptar Permisos:** Windows mostrará la pantalla de Control de Cuentas de Usuario (UAC) preguntando: "¿Quieres permitir que esta aplicación haga cambios en el dispositivo?". Haz clic en **Sí**.
4. **Usar el Menú:** Se abrirá una ventana de consola negra con el título "SHARING WI-FI TO ETHERNET // ICS Manager". Verás el menú principal:
   - Presiona **`1`** y `Enter` para **Iniciar modo red**. Verás la pantalla confirmando que se está compartiendo la conexión.
   - Presiona **`2`** y `Enter` para ver el **Estado de la red** y verificar qué adaptadores fueron detectados y sus IPs.
   - Presiona **`3`** y `Enter` para abrir el **Monitor en vivo** de tráfico en tiempo real y consumo acumulado en GB (puedes detenerlo presionando `Q`).
   - Presiona **`4`** y `Enter` para **Ver historial consumos** y revisar los registros recientes guardados en el archivo local de log.
   - Presiona **`5`** y `Enter` para **Detener modo red** manualmente.
   - Presiona **`6`** y `Enter` para **Salir** de la aplicación de manera limpia.

## ⚠️ Solución de Problemas

- **"No se detectó un adaptador Wi-Fi con conexión a internet":** Verifica que tu laptop esté correctamente conectada a la red Wi-Fi y tengas navegación.
- **"Sin adaptador Ethernet físico detectado":** Windows no detecta que el cable esté conectado. Verifica que el cable esté bien insertado en ambos extremos y que el dispositivo de destino esté encendido.
- **La consola se cierra de inmediato:** Asegúrate de que los archivos `.bat` y `.ps1` se encuentren en la misma carpeta exacta.

---
*Herramienta desarrollada para facilitar implementaciones de red rápidas y seguras en entornos de trabajo Windows.*
