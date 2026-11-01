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
'
DOCKER_BRIDGE='docker0'
DOCKER_SUBNET='172.17.0.0/16'
RULE_PREF='9500'
