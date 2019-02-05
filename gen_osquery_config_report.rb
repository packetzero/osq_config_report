#!/usr/bin/ruby

require 'json'
#require 'ostruct'
require 'digest'
#require 'open3'

class Checker
  attr_accessor :queries, :packs, :options, :errors, :warnings, :details, :interval_stats

  def initialize()
    @queries = []
    @packs = {}
    @options = {}
    @errors = []
    @warnings = []
    @details = {}
    @interval_stats = {}
  end

  #-------------------------------------------------------------
  # Will run makecvl to extract IN() lists from SQL statement expressions.
  # returns the modified sql that uses incvl() calls instead of IN().
  #
  # if sql = "SELECT * FROM blah WHERE path IN('a','b','c')"
  # makecvl will output two lines that look something like:
  #  SELECT * FROM blah WHERE incvl(path,'path_LIST_1')
  #  path_LIST_1:["a","b","c"]
  #
  # This function will alter the list name 'path_LIST_1' to use part
  # of a SHA2 hash of the list (e.g. 'path_eab321fc')
  #
  #
  #-------------------------------------------------------------
  def patch_sql_list(json_obj, query_name, query_obj, sql, value_lists)

    result_lines=`./makecvl/makecvl "#{sql}"`.lines

    if (result_lines.size() < 2)
      # SQL has a list, but does not contain literals
      return nil
    end
    new_sql = result_lines.shift.chomp
    i = -1
    result_lines.each do |list_str|
      i += 1
      suffix = Digest::SHA2.hexdigest(list_str)[0..8]     # first 8 chars of SHA2
      temp_str,value_str = list_str.split(':',2)
      temp_name,xx = temp_str.split('_LIST_')
      value_list_name = "#{temp_name}_#{suffix}"
      new_sql = new_sql.gsub(temp_str, value_list_name)

      # add value list def.
      value_doc = JSON.parse(value_str) rescue nil
      if (value_doc.nil?)
        STDERR.puts "Unable to parse value list to JSON:#{value_str}"
        next
      end

      value_lists[value_list_name] = value_doc
    end
    new_sql
  end

  #-------------------------------------------------------------
  # substitutes IN() with incvl() call and defined value_lists[]
  #-------------------------------------------------------------
  def sub_value_list(obj, sql)
    # skip events tables, they are cached
    return if sql.include?('_events')

    if (sql.downcase.match(/\sin\s?[(]/ ))
      value_lists = {}
      new_sql = patch_sql_list(json_obj, name, obj, sql, value_lists)

      if new_sql.nil?
        return
      end

      obj['query'] = new_sql
      obj['value_lists'] = value_lists
    end
  end

  #-------------------------------------------------------------
  #-------------------------------------------------------------
  def run_report_single_query name, obj, sql
    # TODO: is this from config  or pack (which?)

    #@details[name] = { name: name, sql_raw: sql }
    STDERR.puts "analyzing #{name}"

    cmd="./bin/sqlfmt -s ./data/schema_3.3.1.csv -j \"#{sql}\""
    ##puts "CMD:#{cmd}"
    tmp=`#{cmd}` ### `./bin/sqlfmt -s ./data/schema_3.3.1.csv -j "#{sql}"`
    ##puts "tmp:#{tmp}"


    result = JSON.parse(tmp) rescue nil

    if (result.nil? or result['sql_raw'].nil?)
      STDERR.puts "ERROR analyzing query '#{name}'"
      exit 3
      return
    end

    # fill in details

    result['name'] = name
    interval = obj['interval'] rescue _default_interval;
    result['interval'] = interval
    result['platform'] = obj['platform']
    @details[name] = result

    #puts result.inspect
    #exit 3
  end

  #-------------------------------------------------------------
  # build interval stats
  #-------------------------------------------------------------
  def build_interval_stats
    @interval_stats = {}
    @details.each do |name, obj|
      ival = obj['interval'].to_i
      #puts "#{name} #{ival}"
      if @interval_stats[ival].nil?
        @interval_stats[ival] = []
      end
      stat = { name: obj['name'] , table: obj['table'], joins: [], platform: obj['platform']}
      obj['joins'].each do |talias, fields|
        stat[:joins].push fields['table_name']
      end
      #puts "[#{ival}] = #{JSON.generate(stat)}"
      @interval_stats[ival].push stat
    end
  end


  #-------------------------------------------------------------
  # reads the json_obj node, which is the value for 'schedule'
  # key of the configuration.
  # Populates @table with all table references
  #-------------------------------------------------------------
  def load_sched json_obj
    return if json_obj.nil?

    json_obj.each do |name,obj|       # each scheduled query
      sql = obj['query'] rescue nil
      if sql.nil?
        STDERR.puts "ERROR: unable to read query attr for '#{name}'"
        next
      end

      #sub_value_list obj, sql

      run_report_single_query name, obj, sql

    end
  end

  #-------------------------------------------------------------
  #-------------------------------------------------------------
  def get_bool_option name, default_value
    val = @options[name]
    return default_value if val.nil?
    # could be bool or int, or string
    valstr = val.to_s
    return true if valstr == '1' || valstr.to_s.downcase == 'true'
    false
  end

  def load_packs json_obj
    return if json_obj.nil?

    json_obj.each do |name,filepath|
      @packs[name] = filepath
    end
  end
  def load_options json_obj
    return if json_obj.nil?

    json_obj.each do |name,value|
      @options[name] = value
    end
  end
  def load_flags(lines)
    lines.each do |line|
      line = line.chomp.strip # remove newlines and trim
      line = line.gsub('--',"")
      key,val = line.split('=',2)
      key.downcase!
      next unless key.include?('disable') || key.include?('enable')
      if val.nil?
        if key.include?('enable')
          val = true
        else
          vale = false
        end
      end
      @options[key] = val
    end
    #puts lines.join("||")
  end
end

checker = Checker.new

ARGV.each do |filepath|

  File.open(filepath) do |f|

    if filepath.end_with?('.flags')
      checker.load_flags f.readlines
      next
    end

    obj = JSON.parse(f.read)

    checker.load_options(obj['options'])

    _default_interval = @options['interval'] rescue 3600

    checker.load_sched(obj['queries'])
    checker.load_sched(obj['schedule'])
    checker.load_packs(obj['packs'])

#    obj.each do |key,value|
#      checker.load_sched value if key == "queries" # pack file
#      checker.load_sched value if key == "schedule"
#      checker.load_packs value if key == "packs"
#      checker.load_options value if key == "options"
#      #puts "key:#{key}"
#    end

    #puts JSON.generate(obj)
#    puts JSON.generate checker.details
    checker.build_interval_stats
    puts JSON.generate checker.interval_stats
#    puts "num queries:#{checker.details.count}"
  end
end

#checker.report
