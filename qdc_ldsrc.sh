#!/bin/bash
###
### The goal of this script is to demonstrate Qlik Catalog API capability to categorize and load data. 
### Customers should perform all the necessary test against their environments and requirements. 
### This is not meant for Production use.
###
### The purpose of this script is automatically load all entities within a Qlik Catalog source
### This script utilize number of json files to struct request & response payload. after each load, we should clean up all the .json & .ck files.
### it requires jq utility (https://stedolan.github.io/jq/), jq is a very high-level functional programming language with support for backtracking and managing streams of JSON data.
###

# Defining functions
usage_msg() {
	echo "This script will automatically load all entities within a Qlik Catalog source" 
	echo -e "prerequisites - jq (https://stedolan.github.io/jq/download/)\n"
	echo -e "Usage:\n bash ./qdc_ldsrc.sh [arg: configuration file]\n"
	echo -e " [i.e.] $ ./qdc_ldsrc.sh ./config/qdc_ldsrc.conf > ./tmp/qdc_ldsrc.log 2>&1 &\n"
	echo -e " Configuration file should contain the following variables:"
	echo -e "    hostname=https://dummy.qlikcatalog.com:8180/qdc"
	echo -e "    source_name=sales"
	echo -e "    username=user"
	echo -e "    password=1234"
	echo -e "\n Optional variables:"
	echo -e "    waitload=yes|no (default=no)"
	echo -e "    tmpdir=directory (default=./tmp) \n"
	
}
initial_msg() {
	echo "==========================================================================================="
	echo "(LOG) $(date):: Source Creator - START"
}
end_msg() {
	echo "(LOG) $(date):: Source Creator - END"
	echo "==========================================================================================="
}

### if less than one arguments supplied, display usage 
if [ $# -le 0 ]
then
	usage_msg
	exit 1
fi

#Variable definition
load_date=$(date +%y%m%d%H%M%S)
config_file=$1
[ -z ${tmpdir+x} ] && tmpdir=./tmp
basefileout=$(basename $config_file)$load_date
[ -z ${waitload+x} ] && waitload=no

# open configuration files for input variables
source $config_file

initial_msg

echo "==== Checking input variables" >&2
errsrc=0
[ -z ${hostname+x} ] && errsrc=1
[ -z ${source_name+x} ] && errsrc=1
[ -z ${username+x} ] && errsrc=1
[ -z ${password+x} ] && errsrc=1
[ -z ${waitload+x} ] && errsrc=1
[[ "${waitload}" != 'yes' && "${waitload}" != 'no' ]]  && errsrc=1
if [ $errsrc == 1 ]
then
    echo -e 'Error in the config file. Verify the source parameters !\n'
	usage_msg
	rm -r $tmpdir/$basefileout*.json> /dev/null 2>&1
	rm -r $tmpdir/$basefileout*.ck> /dev/null 2>&1
	end_msg
    exit $?
fi

echo "==== Input Variables" >&2
echo "     Configuration File: ${config_file}"
echo "     hostname..........: ${hostname}" >&2
echo "     source_name.......: ${source_name}" >&2
echo "     username..........: ${username}" >&2
echo "     password..........: <hidden>" >&2
echo "     wait load finish..: ${waitload}" >&2
echo -e "     temp files........: $tmpdir\n" >&2

echo "==== Creating temporary directory to store .json & cookie files"
[ -d $tmpdir ] || mkdir $tmpdir > /dev/null 2>&1

set -e

echo "==== Establish Qlik Catalog session"
curl -s -k -X GET -c $tmpdir/${basefileout}1.ck -L "$hostname/login" --output /dev/null
if [[ $? != 0 ]]
then
    echo 'Error establishing session. Verify the connections parameters !'
	rm -r $tmpdir/$basefileout*.json> /dev/null 2>&1
	rm -r $tmpdir/$basefileout*.ck> /dev/null 2>&1
	end_msg
    exit $?
fi

CSRF_TOKEN1=$(cat $tmpdir/${basefileout}1.ck | grep 'XSRF' | cut -f7)

echo "==== Get a new cookie for this session."
curl -s -k -X POST -c $tmpdir/${basefileout}2.ck -b $tmpdir/${basefileout}1.ck -d "j_username=${username}&j_password=${password}&_csrf=$CSRF_TOKEN1" \
     -H "Content-Type: application/x-www-form-urlencoded" \
	 "$hostname/j_spring_security_check"
if [[ $? != 0 ]]
then
    echo 'Error, logon failed. Verify user and password !'
	rm -r $tmpdir/$basefileout*.json > /dev/null 2>&1
	rm -r $tmpdir/$basefileout*.ck > /dev/null 2>&1
	end_msg
    exit $?
fi

CSRF_TOKEN2=$(cat $tmpdir/${basefileout}2.ck | grep 'XSRF' | cut -f7)

echo "==== Get all existing sources."
outputfile=$tmpdir$config_file
curl -s -k -X GET -b $tmpdir/${basefileout}2.ck \
     -H "Content-Type: application/x-www-form-urlencoded" \
	 -H "X-XSRF-TOKEN:$CSRF_TOKEN2" \
	 "$hostname/source/v1/getSources" \
	 -d "type=EXTERNAL&count=500&sortAttr=name&sortDir=ASC"  \
	 | jq . \
	 > $tmpdir/${basefileout}1.json 

echo "==== Get source id."
tmp_cmd="jq .subList $tmpdir/${basefileout}1.json | jq ' .[] | select(.name==\"$source_name\") | .id'"
cmd_src_id=$(eval "$tmp_cmd") 

echo "==== Get all source entities"
curl -s -k -X GET -b $tmpdir/${basefileout}2.ck \
     -H "Content-Type: application/x-www-form-urlencoded" \
	 -H "X-XSRF-TOKEN:$CSRF_TOKEN2" \
	 "$hostname/entity/v1/byParentId/$cmd_src_id" \
	 -d "count=500&sortAttr=name&sortDir=ASC"  \
	 | jq . \
	 > $tmpdir/${basefileout}2.json 

echo "==== Create json for entity load with entityID"
eval "jq .subList $tmpdir/${basefileout}2.json | jq .[].id | jq -R '.' | jq -s 'map({entityId:.})' > $tmpdir/${basefileout}3.json"

echo "==== Send in request to load entities"
[ "${waitload}" = 'no' ] && bDoAsync='true' || bDoAsync='false'
curl -s -k -X PUT "$hostname/entity/v1/loadDataForEntities/${bDoAsync}" \
     -b ./$tmpdir/${basefileout}2.ck \
     -H "X-XSRF-TOKEN:$CSRF_TOKEN2" \
     -H "accept: */*" \
     -H "Content-Type: application/json" \
     -d @$tmpdir/${basefileout}3.json \
	 > $tmpdir/${basefileout}4.json 

echo -e "==== List of Entities Loaded\nLoadId\tEntityName\tStatus\tLoadTime"  >&2
jq .[] $tmpdir/${basefileout}4.json | jq -r '[.id, .entityName, .status, .loadTime] | @tsv'  >&2
echo -e "==== End of List of Entities Loaded\n"  >&2

echo "==== Clean out all temporay .json & cookie files"
rm -r $tmpdir/*.json > /dev/null 2>&1
rm -r $tmpdir/*.ck   > /dev/null 2>&1

end_msg
