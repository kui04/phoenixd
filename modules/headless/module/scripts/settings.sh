# User settings, sourced by the module scripts.
# Run: headless-service restart
AUTOSTART='1'
WIFI_IFACE='wlan0'
WIFI_TIMEOUT='60'
WIFI_SERVICES='wpa_supplicant wificond vendor.wifi_hal_legacy'
ANDROID_SERVICES='
  zygote zygote_secondary surfaceflinger
  audioserver cameraserver
  media mediaextractor media.swcodec mediametrics
  vendor.hwcomposer-2-4
'
DOCKER_BRIDGE='docker0'
DOCKER_SUBNET='172.17.0.0/16'
RULE_PREF='9500'
CHARGE_CONTROL='1'
CHARGE_START_LEVEL='50'
CHARGE_STOP_LEVEL='65'
CHARGE_INTERVAL='60'
FAST_CHARGE='0'
CHARGE_RESTRICT_CUR='1200000'
DISPLAY_ENABLED='1'
DISPLAY_TIMEOUT='30'
DISPLAY_BRIGHTNESS='1024'
