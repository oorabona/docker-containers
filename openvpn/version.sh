source "../helpers/git-tags"

if [ "$1" == "latest" ]; then
	git-latest-tag openvpn openvpn
else
	git-check-tag openvpn openvpn $1
fi
