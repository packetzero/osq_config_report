#/bin/bash
OSQ_CONFIG_DIR=$1
if [ "${OSQ_CONFIG_DIR}" == "" ] ; then
  echo "ERROR: please specify OSQ_CONFIG_DIR environment variable. It must contain osq config files to analyze."
  echo "usage: $0 <path to config file directory>"
  exit 1
fi

docker build . -t osq_config_report

docker run -it -v $PWD:/src -v ${OSQ_CONFIG_DIR}:/osq_configs -p 8000:8000 osq_config_report
