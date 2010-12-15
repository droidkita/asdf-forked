#!/bin/sh
NEWVER="${1}"
PROG="$0"
ASDFDIR="$(readlink -f $(dirname $PROG)/..)"
ASDFLISP=${ASDFDIR}/asdf.lisp
ASDFASD=${ASDFDIR}/asdf.asd

if [ -z "$NEWVER" ] ; then
  OLDVER="$(grep '         (asdf-version "' $ASDFLISP | cut -d\" -f2)"
  NEWVER="$(echo $OLDVER | perl -npe 's/([0-9].[0-9]+)(\.([0-9]+))?/"${1}.".($3+1)/e')"
fi
echo "Setting ASDF version to $NEWVER"
perl -i.bak -npe 's/^(         \(asdf-version ")[0-9.]+("\))/${1}'"$NEWVER"'${2}/' $ASDFLISP
perl -i.bak -npe 's/^(  :version ")[0-9.]+(")/${1}'"$NEWVER"'${2}/' $ASDFASD
cat<<EOF
To complete the version change, you may:
	git add -u
	git commit
	git tag $NEWVER
EOF
