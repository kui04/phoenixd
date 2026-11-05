# Interactive settings for the phoenixd Layer 1 host. The legacy iptables
# names live in /opt/phoenixd/bin, because Alpine's iptables package is nft
# and this kernel has no nf_tables.
export PATH="/opt/phoenixd/bin:${PATH}"
