#!/bin/bash

IP=$(ip -4 addr | sed -ne 's|^.* inet \([^/]*\)/.* scope global.*$|\1|p' | head -1)

# If $IP is a private IP address, the server must be behind NAT
if echo "$IP" | grep -qE '^(10\.|172\.1[6789]\.|172\.2[0-9]\.|172\.3[01]\.|192\.168)'; then
	echo ""
	echo "It seems this server is behind NAT. What is its public IPv4 address or hostname?"
	echo "We need it for the clients to connect to the server."
	until [[ $ENDPOINT != "" ]]; do
		read -rp "Public IPv4 address or hostname: " -e ENDPOINT
	done
fi

PORT="1194"
PROTOCOL="udp"
APPROVE_INSTALL=${APPROVE_INSTALL:-y}
CIPHER="AES-128-GCM"
CERT_CURVE="prime256v1"
CC_CIPHER="TLS-ECDHE-ECDSA-WITH-AES-128-GCM-SHA256"
DH_TYPE="1" # ECDH
DH_CURVE="prime256v1"
HMAC_ALG="SHA256"
TLS_SIG="1" # tls-crypt
NIC=$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)
if [[ -z $NIC ]]; then
	echo
	echo "Can not detect public interface."
	echo "This needs for setup MASQUERADE."
	until [[ $CONTINUE =~ (y|n) ]]; do
		read -rp "Continue? [y/n]: " -e CONTINUE
	done
	if [[ $CONTINUE == "n" ]]; then
		exit 1
	fi
fi

if [[ ! -e /etc/openvpn/server.conf ]]; then
	apt-get update
	apt-get -y install ca-certificates gnupg
	apt-get install -y openvpn iptables openssl wget ca-certificates curl
fi
# Find out if the machine uses nogroup or nobody for the permissionless group
if grep -qs "^nogroup:" /etc/group; then
	NOGROUP=nogroup
else
	NOGROUP=nobody
fi

if [[ ! -d /etc/openvpn/easy-rsa/ ]]; then
	version="3.0.7"
	wget -O ~/easy-rsa.tgz https://github.com/OpenVPN/easy-rsa/releases/download/v${version}/EasyRSA-${version}.tgz
	mkdir -p /etc/openvpn/easy-rsa
	tar xzf ~/easy-rsa.tgz --strip-components=1 --directory /etc/openvpn/easy-rsa
	rm -f ~/easy-rsa.tgz
	cd /etc/openvpn/easy-rsa/ || return
	echo "set_var EASYRSA_ALGO ec" >vars
	echo "set_var EASYRSA_CURVE $CERT_CURVE" >>vars
	SERVER_CN="cn_$(head /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1)"
	echo "$SERVER_CN" >SERVER_CN_GENERATED
	SERVER_NAME="server_$(head /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1)"
	echo "$SERVER_NAME" >SERVER_NAME_GENERATED
	echo "set_var EASYRSA_REQ_CN $SERVER_CN" >>vars
	# Create the PKI, set up the CA, the DH params and the server certificate
	./easyrsa init-pki
	./easyrsa --batch build-ca nopass
	./easyrsa build-server-full "$SERVER_NAME" nopass
	EASYRSA_CRL_DAYS=3650 ./easyrsa gen-crl
	# Generate tls-crypt key
	openvpn --genkey --secret /etc/openvpn/tls-crypt.key
else
	# If easy-rsa is already installed, grab the generated SERVER_NAME
	# for client configs
	cd /etc/openvpn/easy-rsa/ || return
	SERVER_NAME=$(cat SERVER_NAME_GENERATED)
fi

cp pki/ca.crt pki/private/ca.key "pki/issued/$SERVER_NAME.crt" "pki/private/$SERVER_NAME.key" /etc/openvpn/easy-rsa/pki/crl.pem /etc/openvpn

chmod 644 /etc/openvpn/crl.pem

# Generate server.conf
echo "port $PORT" >/etc/openvpn/server.conf
echo "proto $PROTOCOL" >>/etc/openvpn/server.conf


echo "dev tun
user nobody
group $NOGROUP
persist-key
persist-tun
keepalive 10 120
topology subnet
server 10.8.0.0 255.255.255.0
ifconfig-pool-persist ipp.txt" >>/etc/openvpn/server.conf

# Cloudflare
echo 'push "dhcp-option DNS 1.0.0.1"' >>/etc/openvpn/server.conf
echo 'push "dhcp-option DNS 1.1.1.1"' >>/etc/openvpn/server.conf

echo 'push "redirect-gateway def1 bypass-dhcp"' >>/etc/openvpn/server.conf

echo "dh none" >>/etc/openvpn/server.conf
echo "ecdh-curve $DH_CURVE" >>/etc/openvpn/server.conf

echo "tls-crypt tls-crypt.key 0" >>/etc/openvpn/server.conf

echo "crl-verify crl.pem
ca ca.crt
cert $SERVER_NAME.crt
key $SERVER_NAME.key
auth $HMAC_ALG
cipher $CIPHER
ncp-ciphers $CIPHER
tls-server
tls-version-min 1.2
tls-cipher $CC_CIPHER
client-config-dir /etc/openvpn/ccd
status /var/log/openvpn/status.log
verb 3" >>/etc/openvpn/server.conf

# Create client-config-dir dir
mkdir -p /etc/openvpn/ccd
# Create log dir
mkdir -p /var/log/openvpn
# Enable routing
echo 'net.ipv4.ip_forward=1' >/etc/sysctl.d/20-openvpn.conf

# Apply sysctl rules
sysctl --system

#Restart and enable OpenVPN 
systemctl enable openvpn
systemctl start openvpn

# Add iptables rules in two scripts
mkdir -p /etc/iptables

# Script to add rules
echo "#!/bin/sh
iptables -t nat -I POSTROUTING 1 -s 10.8.0.0/24 -o $NIC -j MASQUERADE
iptables -I INPUT 1 -i tun0 -j ACCEPT
iptables -I FORWARD 1 -i $NIC -o tun0 -j ACCEPT
iptables -I FORWARD 1 -i tun0 -o $NIC -j ACCEPT
iptables -I INPUT 1 -i $NIC -p $PROTOCOL --dport $PORT -j ACCEPT" >/etc/iptables/add-openvpn-rules.sh

# Script to remove rules
echo "#!/bin/sh
iptables -t nat -D POSTROUTING -s 10.8.0.0/24 -o $NIC -j MASQUERADE
iptables -D INPUT -i tun0 -j ACCEPT
iptables -D FORWARD -i $NIC -o tun0 -j ACCEPT
iptables -D FORWARD -i tun0 -o $NIC -j ACCEPT
iptables -D INPUT -i $NIC -p $PROTOCOL --dport $PORT -j ACCEPT" >/etc/iptables/rm-openvpn-rules.sh

chmod +x /etc/iptables/add-openvpn-rules.sh
chmod +x /etc/iptables/rm-openvpn-rules.sh

echo "[Unit]
Description=iptables rules for OpenVPN
Before=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/etc/iptables/add-openvpn-rules.sh
ExecStop=/etc/iptables/rm-openvpn-rules.sh
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target" >/etc/systemd/system/iptables-openvpn.service

systemctl daemon-reload
systemctl enable iptables-openvpn
systemctl start iptables-openvpn
# If the server is behind a NAT, use the correct IP address for the clients to connect to
if [[ $ENDPOINT != "" ]]; then
	IP=$ENDPOINT
fi

# client-template.txt is created so we have a template to add further users later
echo "client" >/etc/openvpn/client-template.txt

echo "proto udp" >>/etc/openvpn/client-template.txt
echo "explicit-exit-notify" >>/etc/openvpn/client-template.txt

echo "remote $IP $PORT
dev tun
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
verify-x509-name $SERVER_NAME name
auth $HMAC_ALG
auth-nocache
cipher $CIPHER
tls-client
tls-version-min 1.2
tls-cipher $CC_CIPHER
redirect-gateway
verb 3" >>/etc/openvpn/client-template.txt

echo ""
echo "Tell me a name for the client."
echo "Use one word only, no special characters."

until [[ $CLIENT =~ ^[a-zA-Z0-9_]+$ ]]; do
	read -rp "Client name: " -e CLIENT
done

CLIENTEXISTS=$(tail -n +2 /etc/openvpn/easy-rsa/pki/index.txt | grep -c -E "/CN=$CLIENT\$")
if [[ $CLIENTEXISTS == '1' ]]; then
	echo ""
	echo "The specified client CN was already found in easy-rsa, please choose another name."
	exit
else
	cd /etc/openvpn/easy-rsa/ || return
	./easyrsa build-client-full "$CLIENT" nopass
	echo "Client $CLIENT added."
fi

homeDir="/home/ignas"

cp /etc/openvpn/client-template.txt "$homeDir/$CLIENT.ovpn"

{
	echo "<ca>"
	cat "/etc/openvpn/easy-rsa/pki/ca.crt"
	echo "</ca>"
	echo "<cert>"
	awk '/BEGIN/,/END/' "/etc/openvpn/easy-rsa/pki/issued/$CLIENT.crt"
	echo "</cert>"
	echo "<key>"
	cat "/etc/openvpn/easy-rsa/pki/private/$CLIENT.key"
	echo "</key>"
	echo "<tls-crypt>"
	cat /etc/openvpn/tls-crypt.key
	echo "</tls-crypt>"
		
} >>"$homeDir/$CLIENT.ovpn"

echo ""
echo "The configuration file has been written to $homeDir/$CLIENT.ovpn."

exit 0
