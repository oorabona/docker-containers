source "../helpers/git-tags"

if [ "$1" == "latest" ]; then
	latest-git-tag openvpn openvpn
else
	check-git-tag openvpn openvpn $1
fi
