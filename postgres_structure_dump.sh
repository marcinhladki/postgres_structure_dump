#!/bin/bash

function usage () {
        printf 'Dump Postgres database into multiple files, (almost) ready for Liquibase\n'
	if [[ -n "$1" ]] 
	then
		printf ' \n%s\nusage:\n' "$1" 
	else
		printf '\n'
	fi
	printf ' -c\tssh connection user@host\n'
	printf ' -d\tdatabase\n'
	printf ' -l\tdirectory for results (default structure_dump)\n'
	printf ' -a\tauthor used in liquibase script (default current username)\n'
	printf ' -e\tdbchangelog everywhere flag\n'
	printf ' -h\tthis message\n'
}

dbceverywhere="no"

while getopts hc:d:l:a:e flag
do
    case "${flag}" in
        c) sshconn=${OPTARG};;
        d) database=${OPTARG};;
        l) locdir=${OPTARG};;
        a) author=${OPTARG};;
        e) dbceverywhere="yes";;
		h | * ) 
			usage
			exit 0
		;;
    esac
done

[[ -n $database ]] || { usage "database is required"; exit 1; }
[[ -n $sshconn ]] || { usage "ssh connection is required"; exit 1; }
[[ -n $locdir ]] || { locdir="$database""_structure_dump"; }
[[ -n $author ]] || { author="$(whoami)" ; }

if [[ "$sshconn" == "localhost" ]] ; then
  printf "dump Postgres database structure using:\n\tlocal database: $database\n\tlocal directory: $locdir\n\tauthor: $author\n"
else
  printf "dump Postgres database structure using:\n\tssh: $sshconn\n\tdatabase: $database\n\tlocal directory: $locdir\n\tauthor: $author\n"
fi
pwdlocdir="$(pwd)/$locdir"

# prepare folders
rm -rf "$pwdlocdir" 2>/dev/null ;
rm -rf "$pwdlocdir"".tmp" 2>/dev/null ;
mkdir "$pwdlocdir";
mkdir "$pwdlocdir"".tmp";
startdir=$(pwd);

# get structure from database
if [[ "$sshconn" == "localhost" ]] ; then
  sudo -u postgres pg_dump -d "$database" -c --if-exists --schema-only --no-owner | \
    sed  -e '/^--$/d' -e 's/^--/##/' > structure_dump.sql;
else
  ssh -C "$sshconn" \
    sudo -u postgres pg_dump -d "$database" -C -c --if-exists --schema-only --no-owner | \
    sed  -e '/^--$/d' -e 's/^--/##/' > structure_dump.sql;
fi
# cut big result file to many small files each for one database object
csplit -z -s -f std structure_dump.sql /##/ '{*}';

# build directory tree for schemas and object types
for f in std*; 
do 
	n=$(sed -n '/##/s/##\s*Name: \(\w*\).*/\1/p' $f | sed 's/\W/_/g');
	t=$(sed -n '/##/s/##\s*Name:[^\;]*; Type: \([^\;]*\);.*/\1/p' $f | sed 's/\W/_/g');
	s=$(sed -n '/##/s/##\s*Name:[^\;]*; Type:[^\;]*; Schema: \(\S*\);.*/\1/p' $f);
	mkdir "$pwdlocdir"/$s 2>/dev/null;
	mkdir "$pwdlocdir"/$s/$t 2>/dev/null; 
	sed '/^##/d' $f >> "$pwdlocdir"/$s/$t/$n.sql;
done;

# add changeset description to *.sql files
if [[ "$dbceverywhere" == "no" ]] ; then
  for f in $pwdlocdir/*/*/*.sql; do
    n="${f##*/}";
    n="${n%%.sql}";
    sed -i -e '1i\--liquibase formatted sql' \
        -e '1i\--changeset '$author':'$n' runOnChange:true endDelimiter:"" stripComments:false' $f ;
  done;
fi;

# build db.changelog.xml files in folders
echo -e '<?xml version="1.1" encoding="UTF-8" standalone="no"?>\n<databaseChangeLog xmlns="http://www.liquibase.org/xml/ns/dbchangelog" xmlns:ext="http://www.liquibase.org/xml/ns/dbchangelog-ext" xmlns:pro="http://www.liquibase.org/xml/ns/pro" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:schemaLocation="http://www.liquibase.org/xml/ns/dbchangelog-ext http://www.liquibase.org/xml/ns/dbchangelog/dbchangelog-ext.xsd http://www.liquibase.org/xml/ns/pro http://www.liquibase.org/xml/ns/pro/liquibase-pro-4.1.xsd http://www.liquibase.org/xml/ns/dbchangelog http://www.liquibase.org/xml/ns/dbchangelog/dbchangelog-4.1.xsd">\n' \
	>header;
echo -e '</databaseChangeLog>\n' >footer;

if [[ "$dbceverywhere" == "yes" ]] ; then
  # db.changelog.xml files for object types in schema, without any specific order of those objects
  for d in "$pwdlocdir"/*/*/ ;
  do
    cat header >$d/db.changelog.xml
    ls -1 $d | sed -n '/\.sql$/s/\(\S*\)\.sql/    <changeSet author="$author" id="\1" runOnChange="true" runInTransaction="true">\n    <sqlFile dbms="postgresql" encoding="UTF-8" relativeToChangelogFile="true" splitStatements="true" endDelimiter=";;;"\n        path="\1.sql"\/>\n    <\/changeSet>\n/p' \
    >>$d/db.changelog.xml;
    cat footer >>$d/db.changelog.xml;
  done;

  # db.changelog.xml for schemas, object types in order
  for d in "$pwdlocdir"/*/ ;
  do
    cat header >$d/db.changelog.xml;
    [ -d $d/SCHEMA ] && echo -e '    <include file="SCHEMA/db.changelog.xml" relativeToChangelogFile="true"/>\n'>>$d/db.changelog.xml;
    [ -d $d/ACL ] && echo -e '    <include file="ACL/db.changelog.xml" relativeToChangelogFile="true"/>\n'>>$d/db.changelog.xml;
    [ -d $d/EXTENSION ] && echo -e '    <include file="EXTENSION/db.changelog.xml" relativeToChangelogFile="true"/>\n'>>$d/db.changelog.xml;
    [ -d $d/FUNCTION ] && echo -e '    <include file="FUNCTION/db.changelog.xml" relativeToChangelogFile="true"/>\n'>>$d/db.changelog.xml;
    [ -d $d/SEQUENCE ] && echo -e '    <include file="SEQUENCE/db.changelog.xml" relativeToChangelogFile="true"/>\n'>>$d/db.changelog.xml;
    [ -d $d/TABLE ] && echo -e '    <include file="TABLE/db.changelog.xml" relativeToChangelogFile="true"/>\n'>>$d/db.changelog.xml;
    [ -d $d/SEQUENCE_OWNED_BY ] && echo -e '    <include file="SEQUENCE_OWNED_BY/db.changelog.xml" relativeToChangelogFile="true"/>\n'>>$d/db.changelog.xml;
    [ -d $d/DEFAULT ] && echo -e '    <include file="DEFAULT/db.changelog.xml" relativeToChangelogFile="true"/>\n'>>$d/db.changelog.xml;
    [ -d $d/CONSTRAINT ] && echo -e '    <include file="CONSTRAINT/db.changelog.xml" relativeToChangelogFile="true"/>\n'>>$d/db.changelog.xml;
    [ -d $d/INDEX ] && echo -e '    <include file="INDEX/db.changelog.xml" relativeToChangelogFile="true"/>\n'>>$d/db.changelog.xml;
    [ -d $d/VIEW ] && echo -e '    <include file="VIEW/db.changelog.xml" relativeToChangelogFile="true"/>\n'>>$d/db.changelog.xml;
    [ -d $d/PROCEDURE ] && echo -e '    <include file="PROCEDURE/db.changelog.xml" relativeToChangelogFile="true"/>\n'>>$d/db.changelog.xml;
    [ -d $d/COMMENT ] && echo -e '    <include file="COMMENT/db.changelog.xml" relativeToChangelogFile="true"/>\n'>>$d/db.changelog.xml;
    cat footer >>$d/db.changelog.xml;
  done;
elif [[ "$dbceverywhere" == "no" ]] ; then
  for d in "$pwdlocdir"/*/ ;
  do
    cat header >$d/db.changelog.xml;
    [ -d $d/SCHEMA ] && echo -e '    <includeAll path="SCHEMA" relativeToChangelogFile="true"/>\n'>>$d/db.changelog.xml;
    [ -d $d/ACL ] && echo -e '    <includeAll path="ACL" relativeToChangelogFile="true"/>\n'>>$d/db.changelog.xml;
    [ -d $d/EXTENSION ] && echo -e '    <includeAll path="EXTENSION" relativeToChangelogFile="true"/>\n'>>$d/db.changelog.xml;
    [ -d $d/FUNCTION ] && echo -e '    <includeAll path="FUNCTION" relativeToChangelogFile="true"/>\n'>>$d/db.changelog.xml;
    [ -d $d/SEQUENCE ] && echo -e '    <includeAll path="SEQUENCE" relativeToChangelogFile="true"/>\n'>>$d/db.changelog.xml;
    [ -d $d/TABLE ] && echo -e '    <includeAll path="TABLE" relativeToChangelogFile="true"/>\n'>>$d/db.changelog.xml;
    [ -d $d/SEQUENCE_OWNED_BY ] && echo -e '    <includeAll path="SEQUENCE_OWNED_BY" relativeToChangelogFile="true"/>\n'>>$d/db.changelog.xml;
    [ -d $d/DEFAULT ] && echo -e '    <includeAll path="DEFAULT" relativeToChangelogFile="true"/>\n'>>$d/db.changelog.xml;
    [ -d $d/CONSTRAINT ] && echo -e '    <includeAll path="CONSTRAINT" relativeToChangelogFile="true"/>\n'>>$d/db.changelog.xml;
    [ -d $d/INDEX ] && echo -e '    <includeAll path="INDEX" relativeToChangelogFile="true"/>\n'>>$d/db.changelog.xml;
    [ -d $d/VIEW ] && echo -e '    <includeAll path="VIEW" relativeToChangelogFile="true"/>\n'>>$d/db.changelog.xml;
    [ -d $d/PROCEDURE ] && echo -e '    <includeAll path="PROCEDURE" relativeToChangelogFile="true"/>\n'>>$d/db.changelog.xml;
    [ -d $d/COMMENT ] && echo -e '    <includeAll path="COMMENT" relativeToChangelogFile="true"/>\n'>>$d/db.changelog.xml;
    cat footer >>$d/db.changelog.xml;
  done;
fi

# main db.changelog
mv "$pwdlocdir/-" "$pwdlocdir/__general";
cat header >"$pwdlocdir"/db.changelog.xml;
ls -1d "$pwdlocdir"/*/ | sed 's/.*'"$locdir"'\/\(.*\)/    <include file="\1\/db.changelog.xml"\/>/' \
	>>"$pwdlocdir"/db.changelog.xml
cat footer >>"$pwdlocdir"/db.changelog.xml;

#cleaning
cd "$startdir" || exit 0;
rm -rf "$pwdlocdir"".tmp";

printf "
Done.
Things worth to check:

\t - database creation - script exists in $locdir/__general/DATABASE, but is not connected to db.changlog system
\t - databasechangelog* presence - if source database were maintained by liquibase
\t - initial values - there is no initial values in tables, they should be added separately

\t - function names - remove parameters from filename
\t - <create or replace> functionality is not used
"
