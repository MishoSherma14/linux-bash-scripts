#!/bin/bash

### It's open sorce script so you can change or modify it! ###


############## Static IP For Debian ##############


show_menu1() {
    echo "which linux base do you use?"
    echo "1. debian"
    echo "2. centos"
}

debian_static_ip() {

apt update
apt upgrade -y
apt install openvswitch-switch -y
systemctl start openvswitch-switch
systemctl enable openvswitch-switch


read -p " Enter the domain name: " DOMAIN
hostnamectl set-hostname ns1.$DOMAIN

ip a
read -p " Enter the Net-interface: " CUR_INTER

SERVER_IP=$(ip -4 addr show dev $CUR_INTER | awk '/inet / {print $2}' | cut -d/ -f1)
GATEWAY=$(ip route show default | awk '/default/ {print $3}')
SUBNET_MASK=$(ip -o -f inet addr show | awk '{print $4}' | cut -d/ -f2 | sed -n 2p)
DNS=$(ip -4 addr show dev $CUR_INTER | awk '/inet / {print $2}' | cut -d/ -f1)
NET_INTER=$(ls -1 /etc/netplan/* | head -n 1)

chmod 600 $NET_INTER

cat << EOF > $NET_INTER
network:
  version: 2
  ethernets:
    $CUR_INTER:
      dhcp4: false
      addresses:
        - $SERVER_IP/$SUBNET_MASK
      routes:
        - to: 0.0.0.0/0
          via: $GATEWAY
      nameservers:
        addresses: [$SERVER_IP, 8.8.8.8]
        search: [$DOMAIN]
EOF

netplan apply
systemctl restart NetworkManager
}


############## Static IP For RHAL & CentOS ##############


centos_static_ip() {

yum update
yum upgrade -y

ip a
read -p " Enter the Net-interface: " CUR_INTER

SERVER_IP=$(ip -4 addr show dev $CUR_INTER | awk '/inet / {print $2}' | cut -d/ -f1)
GATEWAY=$(ip route show default | awk 'NR==1 {print $3}')
DNS=$(ip -4 addr show dev $CUR_INTER | awk '/inet / {print $2}' | cut -d/ -f1)
SUBNET_MASK=$(ifconfig $CUR_INTER | grep -oP '(?<=netmask\s)\d+(\.\d+){3}' | head -n 1)
NET_INTER=$(ls -1 /etc/sysconfig/network-scripts/ifcfg-* | head -n 1)

cat <<EOF > $NET_INTER
TYPE=Ethernet
BOOTPROTO=static
DEFROUTE=yes
PEERDNS=yes
PEERROUTES=yes
IPV4_FAILURE_FATAL=no
IPV6INIT=yes
IPV6_AUTOCONF=yes
IPV6_DEFROUTE=yes
IPV6_PEERDNS=yes
IPV6_PEERROUTES=yes
IPV6_FAILURE_FATAL=no
NAME=$CUR_INTER
DEVICE=$CUR_INTER
ONBOOT=yes
IPADDR=$SERVER_IP
NETMASK=$SUBNET_MASK
GATEWAY=$GATEWAY
DNS1=$DNS
DNS2=8.8.8.8
EOF

ip addr flush dev $CUR_INTER
systemctl restart network
}


read -p "Enter your linux base (1.debian, 2.centos): " choice1

case "$choice1" in
    1)
        debian_static_ip
        ;;
    2)
        centos_static_ip
        ;;
    *)
        echo "Invalid choice. Please enter 1 or 2."
        ;;
esac



############## DNS For Debian ##############



debian_install_dns() {
apt update
apt install bind9 bind9utils bind9-doc -y
apt install ufw -y

systemctl start bind9

ufw enable

ufw allow Bind9
ufw allow 53
ufw reload


ZONE_FILE="$DOMAIN.db"
FI_TH_OCTETS=$(echo "$SERVER_IP" | awk -F '.' '{print $3"."$2"."$1}')
REVERSE_ZONE="${FI_TH_OCTETS}.in-addr.arpa"
REVERSE_ZONE_FILE="$REVERSE_ZONE.db"
LAST_OCTET=$(echo "$SERVER_IP" | awk -F '.' '{print $4}')


cat << EOF > /etc/bind/named.conf.options
acl "trusted" {
        $SERVER_IP;    # ns1
};

options {
	directory "/var/cache/bind";

        recursion yes;                 
        allow-recursion { trusted; };  
        listen-on { any; };   
        allow-transfer { none; };      

        forwarders {
                $SERVER_IP;
                8.8.8.8;
        };

};
EOF

cat << EOF >> /etc/bind/named.conf.local
zone "$DOMAIN" IN {
	type master;
	file "/etc/bind/zones/$ZONE_FILE";
	allow-update { none; };
};

zone "$REVERSE_ZONE" IN {
	type master;
	file "/etc/bind/zones/$REVERSE_ZONE_FILE";
	allow-update { none; };
};
EOF

mkdir /etc/bind/zones

cat << EOF > /etc/bind/zones/$ZONE_FILE
\$TTL 3H
@   IN  SOA     ns1.$DOMAIN. root.$DOMAIN. (
                        2022020 ;Serial
                        1D      ;Refresh
                        1H      ;Retry
                        1W      ;Expire
                        3H      ;Minimum TTL
)

@       IN      NS      ns1.$DOMAIN.
@       IN      A       $SERVER_IP
ns1     IN      A       $SERVER_IP
EOF

cat << EOF > /etc/bind/zones/$REVERSE_ZONE_FILE
\$TTL 3H
@   IN  SOA     ns1.$DOMAIN. root.$DOMAIN. (
                        2022020 ;Serial
                        1D      ;Refresh
                        1H      ;Retry
                        1W      ;Expire
                        3H      ;Minimum TTL
)
@       IN      NS      ns1.$DOMAIN.
$LAST_OCTET     IN      PTR     ns1.$DOMAIN.
EOF

read -p "Do you have FTP server? (Y/N): " ftp

if [ "$ftp" = "y" ]; then
	cat << EOF >> /etc/bind/zones/$ZONE_FILE
ftp	IN	A	$SERVER_IP
EOF

elif [ "$ftp" = "n" ]; then
	echo "you don't have FTP server"
fi


read -p "Do you have any clients? (Y/N): " client

if [ "$client" = "y" ]; then
	read -p "Enter the number of clients: " num_clients
	if [ "$num_clients" -eq 0 ]; then
		echo "You don't have any clients."
	else
		for ((i=1; i<=$num_clients; i++)); do
			read -p "Enter client name for client $i: " cl_name
			read -p "Enter client IP address for client $i: " cl_IP
			cl_last_octet=$(echo "$cl_IP" | cut -d '.' -f 4)
cat << EOF >> "/etc/bind/zones/$ZONE_FILE"
$cl_name        IN      A       $cl_IP
EOF

cat <<EOF >> /etc/bind/zones/$REVERSE_ZONE_FILE
$cl_last_octet	IN	PTR	$cl_name.$DOMAIN
EOF
done
	fi
fi


read -p "Do you want to have another forward zones? (Y/N):" choice4
if [ "$choice4" = "y" ]; then
	read -p "Enter the number of forward zones to create: " NUM_ZONES
	for ((i=1; i<=NUM_ZONES; i++)); do
    read -p "Enter forward zone $i name: " FORWARD_ZONE_NAME
    read -p "Enter forward zone $i file: " FORWARD_ZONE_FILE

    cat << EOF >> /etc/bind/named.conf.local

         zone "$FORWARD_ZONE_NAME" IN {
            type master;
            file "/etc/bind/zones/$FORWARD_ZONE_FILE";
            allow-update { none; };
    };
EOF


cat << EOF > /etc/bind/zones/$FORWARD_ZONE_FILE
\$TTL 3H
@   IN  SOA     ns1.$DOMAIN. root.$DOMAIN. (
                            2022020 ;Serial
                            1D      ;Refresh
                            1H      ;Retry
                            1W      ;Expire
                            3H      ;Minimum TTL
)

@       IN      NS      ns1.$DOMAIN.
ns1     IN      A       $SERVER_IP
www	IN	CNAME	@
EOF
done
fi

sed -i "s/nameserver [0-9]*\.[0-9]*\.[0-9]*\.[0-9]*/nameserver $SERVER_IP/g" /etc/resolv.conf
sed -i "s/search [0-9]*\.[0-9]*\.[0-9]*\.[0-9]*/search $DOMAIN/g" /etc/resolv.conf

chown :bind /etc/bind/zones/$ZONE_FILE
chown :bind /etc/bind/zones/$REVERSE_ZONE_FILE

systemctl restart bind9

echo "DNS Server Is Working for debian!"
}


############## DNS For CentOS ##############


centos_install_dns() {
yum update
yum install bind bind-utils -y

systemctl enable named
systemctl start named


firewall-cmd --add-service=dns --permanent
firewall-cmd --add-port=53/tcp --permanent
firewall-cmd --add-port=53/udp --permanent
firewall-cmd --reload


NAMED_CONF="/etc/named.conf"
ALLOW_QUERY="any;"
LISTEN_ON="any;"


sed -i "s/allow-query {.*};/allow-query { $ALLOW_QUERY };/" "$NAMED_CONF"
sed -i "s/listen-on port 53 {.*};/listen-on port 53 { $LISTEN_ON };/" "$NAMED_CONF"


read -p "Enter the domain name: " DOMAIN
hostnamectl set-hostname ns1.$DOMAIN


ZONE_FILE="$DOMAIN.db"
FI_TH_OCTETS=$(echo "$SERVER_IP" | awk -F '.' '{print $3"."$2"."$1}')
REVERSE_ZONE="${FI_TH_OCTETS}.in-addr.arpa"
REVERSE_ZONE_FILE="$REVERSE_ZONE.db"
LAST_OCTET=$(echo "$SERVER_IP" | awk -F '.' '{print $4}')

cat << EOF >> /etc/named.conf
zone "$DOMAIN" IN {
	type master;
	file "$ZONE_FILE";
	allow-update { none; };
};

zone "$REVERSE_ZONE" IN {
	type master;
	file "$REVERSE_ZONE_FILE";
	allow-update { none; };
};
EOF


cat << EOF > /var/named/$ZONE_FILE
\$TTL 3H
@   IN  SOA     ns1.$DOMAIN. root.$DOMAIN. (
			2022020 ;Serial
        		1D      ;Refresh
        		1H      ;Retry
        		1W      ;Expire
       	 		3H      ;Minimum TTL
)

@	IN	NS	ns1.$DOMAIN.
@	IN	A	$SERVER_IP
ns1	IN	A	$SERVER_IP
EOF

cat << EOF > /var/named/$REVERSE_ZONE_FILE
\$TTL 3H
@   IN  SOA     ns1.$DOMAIN. root.$DOMAIN. (
                        2022020 ;Serial
                        1D      ;Refresh
                        1H      ;Retry
                        1W      ;Expire
                        3H      ;Minimum TTL
)
@	IN	NS	ns1.$DOMAIN.
$LAST_OCTET	IN	PTR	ns1.$DOMAIN.
EOF


read -p "Do you have FTP server? (Y/N):" FTP

if [ "$FTP" = "y" ]; then
        cat << EOF >> /var/named/$ZONE_FILE
ftp     IN      A       $SERVER_IP
EOF

elif [ "$FTP" = "n" ]; then
        echo "you don't have FTP server"
fi


read -p "Do you have any clients? (Y/N): " client

if [ "$client" = "y" ]; then
        read -p "Enter the number of clients: " num_clients
        if [ "$num_clients" -eq 0 ]; then
                echo "You don't have any clients."
        else
                for ((i=1; i<=$num_clients; i++)); do
                        read -p "Enter client name for client $i: " cl_name
                        read -p "Enter client IP address for client $i: " cl_IP
                        cl_last_octet=$(echo "$cl_IP" | cut -d '.' -f 4)
cat << EOF >> "/var/named/$ZONE_FILE"
$cl_name        IN      A       $cl_IP
EOF

cat <<EOF >> /var/named/$REVERSE_ZONE_FILE
$cl_last_octet  IN      PTR     $cl_name.$DOMAIN
EOF
done
        fi
fi


read -p "Do you want to have another forward zones? (Y/N): " choice3
if [ "$choice3" = "y" ]; then
	read -p "Enter the number of forward zones" NUM_ZONES
for ((i=1; i<=NUM_ZONES; i++)); do
    read -p "Enter forward zone $i name: " FORWARD_ZONE_NAME
    read -p "Enter forward zone $i file: " FORWARD_ZONE_FILE

    cat << EOF >> /etc/named.conf

         zone "$FORWARD_ZONE_NAME" IN {
            type master;
            file "$FORWARD_ZONE_FILE";
            allow-update { none; };
    };
EOF

cat << EOF > /var/named/$FORWARD_ZONE_FILE
\$TTL 3H
@   IN  SOA     ns1.$DOMAIN. root.$DOMAIN. (
                            2022020 ;Serial
                            1D      ;Refresh
                            1H      ;Retry
                            1W      ;Expire
                            3H      ;Minimum TTL
)

@       IN      NS      ns1.$DOMAIN.
@       IN      A       $SERVER_IP
www     IN      CNAME   @
EOF
done

else [ "$choice3" = "n" ] then
echo "you do not have another forward zones"
fi


sed -i '/nameserver/d' /etc/resolv.conf
echo "nameserver $SERVER_IP" >> /etc/resolv.conf

chown :named /var/named/$ZONE_FILE
chown :named /var/named/$REVERSE_ZONE_FILE

systemctl restart named

echo "DNS server is working for RHAL & centos!"
}

############# Apache For Debian #############


debian_install_apache() {
apt update
apt install apache2 -y

ufw allow 'Apache'
curl -4 icanhazip.com

systemctl start apache2
systemctl enable apache2

mkdir /var/www/$DOMAIN

cat << EOF >> /var/www/$DOMAIN/index.html
<html>
    <head>
        <title>Welcome to $DOMAIN!</title>
    </head>
    <body>
        <h1>Success!  The $DOMAIN virtual host is working!</h1>
    </body>
</html>
EOF

USER=$('whoami')

chown -R $USER:$USER /var/www/$DOMAIN
chmod -R 755 /var/www/$DOMAIN

cat << EOF >> /etc/apache2/sites-available/$DOMAIN.conf
<VirtualHost *:80>
    ServerAdmin webmaster@localhost
    ServerName $DOMAIN
    ServerAlias www.$DOMAIN
    DocumentRoot /var/www/$DOMAIN
    ErrorLog ${APACHE_LOG_DIR}/error.log
    CustomLog ${APACHE_LOG_DIR}/access.log combined
</VirtualHost>
EOF

a2ensite $DOMAIN.conf
a2dissite 000-default.conf
apache2ctl configtest

read -p "Do you have another sites? (Y/N): " site

if [ "$site" = "y" ]; then
	read -p "Enter the number of sites: " sit_num
	if [ "$sit_num" -eq 0 ]; then
		echo "You don't have another sites"
	else
                for ((i=1; i<=$sit_num; i++)); do
			read -p "Enter new site name (domain name) $i: " dom
			mkdir /var/www/$dom

cat << EOF >> /var/www/$dom/index.html
<html>
    <head>
        <title>Welcome to $dom!</title>
    </head>
    <body>
        <h1>Success!  The $dom virtual host is working!</h1>
    </body>
</html>
EOF

USER=$('whoami')

chown -R $USER:$USER /var/www/$dom
chmod -R 755 /var/www/$dom


cat << EOF >> /etc/apache2/sites-available/$dom.conf
<VirtualHost *:81>
    ServerAdmin webmaster@localhost
    ServerName $dom
    ServerAlias www.$dom
    DocumentRoot /var/www/$dom
    ErrorLog ${APACHE_LOG_DIR}/error.log
    CustomLog ${APACHE_LOG_DIR}/access.log combined
</VirtualHost>
EOF

a2ensite $dom.conf
a2dissite 000-default.conf
apache2ctl configtest

done
	fi
fi

systemctl restart apache2

echo "Apache Server Is Working For Debian!"

}


############## Apache For CentOS ##############


centos_install_apache() {
yum update
yum install httpd -y

firewall-cmd --add-service=http --permanent
firewall-cmd --add-service=https --permanent
firewall-cmd --reload

systemctl start httpd
systemctl enable httpd

mkdir -p /var/www/$DOMAIN/html
mkdir -p /var/www/$DOMAIN/log

cat << EOF > /var/www/$DOMAIN/html/index.html
<html>
  <head>
    <title>Welcome to your website!</title>
  </head>
  <body>
    <h1>Success! The $DOMAIN virtual host is working!</h1>
  </body>
</html>
EOF

mkdir /etc/httpd/sites-available /etc/httpd/sites-enabled

cat << EOF >> /etc/httpd/conf/httpd.conf
IncludeOptional sites-enabled/*.conf
EOF

cat << EOF > /etc/httpd/sites-available/$DOMAIN.conf
<VirtualHost *:80>
    ServerName www.$DOMAIN
    ServerAlias $DOMAIN
    DocumentRoot /var/www/$DOMAIN/html
    ErrorLog /var/www/$DOMAIN/log/error.log
    CustomLog /var/www/$DOMAIN/log/requests.log combined
</VirtualHost>
EOF

ln -s /etc/httpd/sites-available/$DOMAIN.conf /etc/httpd/sites-enabled/$DOMAIN.conf

USER=$('whoami')

chown -R $USER:apache /var/www/$DOMAIN/
chmod -R 755 /var/www/$DOMAIN

setsebool -P httpd_unified 1
ls -dZ /var/www/$DOMAIN/log/
semanage fcontext -a -t httpd_log_t "/var/www/$DOMAIN/log(/.*)?"
restorecon -R -v /var/www/$DOMAIN/log

systemctl enable httpd
systemctl start httpd

systemctl restart httpd

read -p "Do you have another sites? (Y/N): " site

if [ "$site" = "y" ]; then
        read -p "Enter the number of sites: " sit_num
        if [ "$sit_num" -eq 0 ]; then
                echo "You don't have another sites"
        else
                for ((i=1; i<=$sit_num; i++)); do
                        read -p "Enter new site name (domain name) $i: " dom
			mkdir -p /var/www/$dom/html
			mkdir -p /var/www/$dom/log

cat << EOF >> /var/www/$dom/index.html
<html>
    <head>
        <title>Welcome to $dom!</title>
    </head>
    <body>
        <h1>Success!  The $dom virtual host is working!</h1>
    </body>
</html>
EOF

chown -R $USER:apache /var/www/$dom/
chmod -R 755 /var/www/$dom

cat << EOF > /etc/httpd/sites-available/$dom.conf
<VirtualHost *:81>
    ServerName www.$dom
    ServerAlias $dom
    DocumentRoot /var/www/$dom/html
    ErrorLog /var/www/$dom/log/error.log
    CustomLog /var/www/$dom/log/requests.log combined
</VirtualHost>
EOF

ln -s /etc/httpd/sites-available/$dom.conf /etc/httpd/sites-enabled/$dom.conf

setsebool -P httpd_unified 1
ls -dZ /var/www/$dom/log/
semanage fcontext -a -t httpd_log_t "/var/www/$dom/log(/.*)?"
restorecon -R -v /var/www/$dom/log
done
        fi
fi

echo "Apache service is working for RHAL & centos!"
}


############# FTP For Debian ############


debian_install_ftp() {
apt update
apt install vsftpd -y
apt install ftp -y
apt install lftp -y

systemctl start vsftpd
systemctl enable vsftpd

cp /etc/vsftpd.conf /etc/vsftpd_default

read -p "enter user name for FTP:" FTPUSER

useradd -m $FTPUSER
passwd $FTPUSER

ufw allow 20/tcp
ufw allow 21/tcp

sed -i 's/^#write_enable=YES$/write_enable=YES/' /etc/vsftpd.conf
sed -i 's/^#chroot_local_user=YES$/chroot_local_user=YES/' /etc/vsftpd.conf
sed -i 's/^ssl_enable=NO$/ssl_enable=YES/' /etc/vsftpd.conf
sed -i 's|^#chroot_list_file=/etc/vsftpd.chroot_list$|chroot_list_file=/etc/vsftpd.chroot_list|' /etc/vsftpd.conf

mkdir /srv/ftp/user_list
usermod -d /srv/ftp/user_list $FTPUSER

chown -R $FTPUSER /srv/ftp

openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout /etc/ssl/private/vsftpd.pem -out /etc/ssl/private/vsftpd.pem

cat << EOF >> /etc/vsftpd.conf
rsa_cert_file=/etc/ssl/private/vsftpd.pem
rsa_private_key_file=/etc/ssl/private/vsftpd.pem
allow_anon_ssl=NO
force_local_data_ssl=YES
force_local_logins_ssl=YES
ssl_tlsv1=YES
ssl_sslv2=NO
ssl_sslv3=NO
require_ssl_reuse=NO
ssl_ciphers=HIGH
pasv_min_port=40000
pasv_max_port=50000
EOF

systemctl restart vsftpd

lftp ftps://$FTPUSER@ftp.$DOMAIN

echo "FTP Server Is Working!"
}


debian_install_dns_apache() {
        debian_install_dns
        debian_install_apache
}

debian_install_dns_apache_ftp() {
        debian_install_dns
        debian_install_apache
        debian_install_ftp
}


centos_install_dns_apache() {
        centos_install_dns
        centos_install_apache
}

centos_install_dns_apache() {
        centos_install_dns
        centos_install_apache
}



read -p "Enter your choice 
	
	(1.DNS for debian, 
 	 2.Apache for debian, 
	 3.FTP for debian, 
	 4.DNS_Apache for debian, 
	 5.DNS_Apache_FTP for debian, 

	 6.DNS for contos, 
	 7.Apache for centos, 
	 8.DNS_Apache for centos): " choice2

case "$choice2" in
    1)
        debian_install_dns
        ;;
    2)
        debian_install_apache
        ;;
    3)
        debian_install_ftp
        ;;
    4)
        debian_install_dns_apache
        ;;
    5)
        debian_install_dns_apache_ftp
        ;;
    6)
        centos_install_dns
        ;;
    7)
        centos_install_apache
        ;;
    8)
        centos_install_dns_apache
        ;;
    *)
        echo "Invalid choice. Please enter 1, 2, 3, 4, 5, 6, 7, or 8."
        ;;
esac
