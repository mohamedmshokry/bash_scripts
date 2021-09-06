#!/bin/bash

#################################################################################################
#Script Name	: Calculate Elasticsearch closed Indices size                                                                                        
#Description	: Calculate Elasticsearch data pods closed indices sizes on disk                              
#Args           : None                                                   
#Author       	: Mohamed Shokry                                                
#Email         	: mohamed.magdyshokry@gmail.com                                           
#################################################################################################

# Note: Script is crafted for Elasticsearch kubernetes based deployment. Same idea can be used with tuning for "kubectl exec" for other types of deployments 

# Paramters description
##############################
# ES_DATA_POD_COUNT		: Contains current active and running Elasticsearch data pods
# CLOSED_INDICES		: Contains UUIDs of closed indices
# SIZES_UNCLEAN			: Contains List of indices sizes with GB suffix
# CALCULATION_TEMP_FILE	: Optional name for temp file 


ES_DATA_POD_COUNT=$(curl -sXGET  elasticsearch.cgnat.svc.cluster.local:9200/_cat/nodes?h=name,nodeRole | grep -i di | wc -l)
CLOSED_INDICES=$(curl -sXGET http://elasticsearch.cgnat.svc.cluster.local:9200/_cat/indices?v | grep -i close | awk '{print$3}')


echo -e "\033[1;92mCurrent active elastisearch data pods = \033[1;36m $ES_DATA_POD_COUNT \033[0m"
echo -e '\033[1;92mRemoving old temp files ...\033[0m'
rm -rf closed_indices_data*
echo -e '\033[1;92mExtracting closed indices sizes from all active elasticsearch data pods ...\033[0m'
echo -e '\033[1;94mBe patient it takes time ...\033[0m'
for STS_ID in $(seq 0 $(expr $ES_DATA_POD_COUNT - 1));
do
	# get closed indieces "Mostly nat-log-* indices"
	
	# Get size of closed indices per node
	for index_uuid in $CLOSED_INDICES;
	do 
		kubectl exec -it -n cgnat cgnat-belk-elasticsearch-data-$STS_ID -- du -sh /data/data/nodes/0/indices/$index_uuid/ >> closed_indices_data-$STS_ID.info
	done
	SIZES_UNCLEAN=$(cat closed_indices_data-$STS_ID.info | awk '{print$1}')
	# Cleaning closed indices size list
	for size in $SIZES_UNCLEAN;
	do 
		echo ${size%?} >> closed_indices_data-$STS_ID.size
	done
	# Calculating total count of closed indices files per node
	cat closed_indices_data-$STS_ID.size | awk -v ID="$STS_ID" '{size +=$1}END {print "\033[0;93mTotal closed indices files size on node cgnat-belk-elasticsearch-data-"ID" =  \033[1;93m"size" GB \033[0m"}'
done