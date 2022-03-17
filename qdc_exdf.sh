#!/bin/bash
###
### The goal of this script is to demonstrate Qlik Catalog API capability to categorize and load data. 
### Customers should perform all the necessary test against their environments and requirements. 
### This is not meant for Production use.
###
### The purpose of this script is automatically execute the DataFlows within a Qlik Catalog
### This script utilize number of json files to struct request & response payload. after each load, we should clean up all the .json & .ck files.
### it requires jq utility (https://stedolan.github.io/jq/), jq is a very high-level functional programming language with support for backtracking and managing streams of JSON data.
###

# Defining functions
usage_msg() {
	echo "This script will automatically execute the DataFlows within a Qlik Catalog" 
	echo -e "prerequisites - jq (https://stedolan.github.io/jq/download/)\n"
	echo -e "Usage:\n bash ./qdc_exdf.sh [arg: configuration file]\n"
	echo -e " [i.e.] $ ./qdc_exdf.sh ./config/qdc_exdf.conf > ./tmp/qdc_exdf.log 2>&1 &\n"
	echo -e " Configuration file should contain the following variables:"
	echo -e "    hostname=https://dummy.qlikcatalog.com:8180/qdc"
	echo -e "    dataflow_name=PrepSales"
	echo -e "    username=user"
	echo -e "    password=1234"
	echo -e "\n Optional variables:"
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

# open configuration files for input variables
source $config_file

initial_msg

echo "==== Checking input variables" >&2
errsrc=0
[ -z ${hostname+x} ] && errsrc=1
[ -z ${source_name+x} ] && errsrc=1
[ -z ${dataflow_name+x} ] && errsrc=1
[ -z ${username+x} ] && errsrc=1
[ -z ${password+x} ] && errsrc=1

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
echo "     dataflow_name.......: ${source_name}" >&2
echo "     username..........: ${username}" >&2
echo "     password..........: <hidden>" >&2
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

echo "==== Get dataFlow id."
outputfile=$tmpdir$config_file
curl -s -k -X GET -b $tmpdir/${basefileout}2.ck \
     -H "Content-Type: application/json" \
	 -H "X-XSRF-TOKEN:$CSRF_TOKEN2" \
	 "$hostname/transformation/v1/getDataflowId?dataflowName=${dataflow_name}" \
	 | jq . \
	 > $tmpdir/${basefileout}1.json 



cmd_df_id=$(eval "jq .objectId $tmpdir/${basefileout}1.json")
echo "DataFlow id ${cmd_df_id}"

echo "==== Execute DataFlow"
CSRF_SESSIONID=$(cat $tmpdir/${basefileout}2.ck | grep 'JSESSIONID' | cut -f7)
cmd_exdf="curl -s -k \"$hostname/transformation/execute/${cmd_df_id}/LOCAL?bValidate=false&loadType=DATA\" -X 'PUT' -H 'Connection: keep-alive' -H 'Content-Length: 0' -H 'Accept: application/json, text/plain, */*' -H \"X-XSRF-TOKEN:$CSRF_TOKEN2\" -H \"Cookie: JSESSIONID=$CSRF_SESSIONID; XSRF-TOKEN=$CSRF_TOKEN2\" --insecure "
eval $cmd_exdf

echo -e "\n==== Clean out all temporay .json & cookie files"
rm -r $tmpdir/*.json > /dev/null 2>&1
rm -r $tmpdir/*.ck   > /dev/null 2>&1

end_msg
