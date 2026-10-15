#!/bin/bash
# simule un shell GNOME muet : le nom existe, l'introspection ne repond pas
for a in "$@"; do [ "$a" = "org.freedesktop.DBus.NameHasOwner" ] && { echo '(true,)'; exit 0; }; done
exit 1
