#!/bin/bash
#
# freqtrade_download_pairs.sh
# by nightshift2k (join.the.nightshift@protonmail.com)
#
# This script downloads all pairs from one ore more exchange(s)
# for one or more quote coin(s) and is currently not suitable
# for usage inside docker but should be easily adaptable
#
# PREREQUISITES: 
#    jq from https://stedolan.github.io/jq/
#    or available in all major linux distros
#
# ANNOTATIONS:
#   I haven't tested all exchanges, and it may very well
#   be that for some less used/known exchange the download
#   doesn't work very stable (e.g. coinex) you might have to 
#   provide an extra config file with ratelimits
#   
###
# set your dirs accordingly
###
FQT_DIR="/opt/freqtrade"
LOG_DIR="${FQT_DIR}/user_data/logs"
TMP_DIR="/tmp"

###
# define exchanges as array (a b c)
# EXCHANGES=(binance coinex huobipro ftx gateio)
# define one ore more quotecoins as array (USDT ETH BTC)
# QUOTECOINS=(USDT ETH BTC)
###
EXCHANGES=(binance ftx)
QUOTECOINS=(BUSD USDT)

### 
# rate limits for exchanges, by no means complete!
# just a little try and error, fallback to default
# rate limit if not defined
# could still fail if an exchange is restrictive
# in its public API's ¯\_(ツ)_/¯
###
DEFAULT_RATELIMIT=500
declare -A RATELIMITS=([binance]=300 [coinex]=1000 [ftx]=250 [huobipro]=250 [kraken]=3100) 

###
# define timeframes as string "5m 1h 1d"
# define amount of days to get historical data from today on
###
TIMEFRAMES="3m 5m 1h 4h"
DAYS=30

### PID FILE CHECK NOT TO START ANOTHER DOWNLOAD ######################################################################
PIDFILE="/var/run/$(basename ${0}|cut -d '.' -f 1).pid"
if [ -f $PIDFILE ]
then
  PID=$(cat $PIDFILE)
  ps -p $PID > /dev/null 2>&1
  if [ $? -eq 0 ]
  then
    echo "another instance is already running"
    exit 1
  else
    ## Process not found assume not running
    echo $$ > $PIDFILE
    if [ $? -ne 0 ]
    then
      echo "Could not create PID file"
      exit 1
    fi
  fi
else
  echo $$ > $PIDFILE
  if [ $? -ne 0 ]
  then
    echo "Could not create PID file"
    exit 1
  fi
fi

### MAIN LOGIC  #######################################################################################################

# switch to freqtrade venv
cd ${FQT_DIR};
source .env/bin/activate ; 

# loop through exchanges
for EXCHANGE in ${EXCHANGES[@]}
do
  if [[ ${RATELIMITS[$EXCHANGE]} -gt 0 ]]
  then
    RATELIMIT=${RATELIMITS[$EXCHANGE]}
  else
    RATELIMIT=${DEFAULT_RATELIMIT}
  fi
  echo "exchange ${EXCHANGE} needs ratelimit ${RATELIMIT}";
  echo "{\"exchange\":{\"name\":\"${EXCHANGE}\",\"ccxt_config\":{\"enableRateLimit\":true,\"rateLimit\":${RATELIMIT}},\"ccxt_async_config\":{\"enableRateLimit\":true,\"rateLimit\":${RATELIMIT}}}}" | jq . > ${TMP_DIR}/rate_limit_config_${EXCHANGE}.json
    # loop through quote coins
  for COIN in ${QUOTECOINS[@]}
  do
    COIN=${COIN^^} # upcase it because its case sensitive!
    TMP_DATE=$(date +%s)
    TMP_FILE=${TMP_DIR}/${TMP_DATE}_${EXCHANGE}_${COIN}.json
    LOG_FILE=${LOG_DIR}/${TMP_DATE}_pair_download_${EXCHANGE}_${COIN}.log
    echo "listing ${EXCHANGE} ${COIN} pairs into ${TMP_FILE}"
    freqtrade list-pairs --exchange ${EXCHANGE} --quote ${COIN} --print-json > ${TMP_FILE} 2>/dev/null
    # sanity check, if json is empty (exchange under maintenance or wrong stakecoin)
    PAIR_COUNT=$(jq length ${TMP_FILE})
    if [[ $PAIR_COUNT -gt 1 ]]
    then
      echo "exchange ${EXCHANGE} has currently ${PAIR_COUNT} pairs for ${COIN} - starting download for timeframes = ${TIMEFRAMES}, days = ${DAYS}"
      START=$(date +%s)
      # >>> main magic! :)
      freqtrade download-data --config ${TMP_DIR}/rate_limit_config_${EXCHANGE}.json --pairs-file ${TMP_FILE} --days ${DAYS} --timeframes ${TIMEFRAMES} --exchange ${EXCHANGE} --logfile ${LOG_FILE} 
      #2>/dev/null
      END=$(date +%s)
      DIFF=$(echo "${END} - ${START}" | bc)
      echo "exchange ${EXCHANGE} pair download for ${COIN} completed in ${DIFF}s"
    else
      echo "exchange ${EXCHANGE} has currently no pairs available for ${COIN}"
    fi
    # clear out temp json
    rm ${TMP_FILE}
  done 
  rm ${TMP_DIR}/rate_limit_config_${EXCHANGE}.json
done

# PID remove
rm $PIDFILE
