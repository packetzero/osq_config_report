#!/bin/bash
cd /src/

# generate

ruby ./gen_osq_config_report.rb /osq_configs/*

# serve

ruby -rwebrick -e'WEBrick::HTTPServer.new(:Port => 8000, :DocumentRoot => Dir.pwd + "/out/").start'
