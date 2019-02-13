#!/usr/bin/ruby

require 'json'
#require 'ostruct'
require 'digest'
#require 'open3'
require 'fileutils'

class Checker
  attr_accessor :queries, :packs, :options, :errors, :warnings, :details
  attr_accessor :interval_stats, :stat_profile, :config_files, :table_queries, :platforms

  def initialize()
    @queries = []
    @config_files = []
    @packs = {}
    @options = {}
    @errors = []
    @warnings = []
    @details = {}
    @platforms = {} # 'platform_name' => num_queries
    @table_queries = {} # 'table_name' => { queries:[ query list ], joins: [ query list] }
    @interval_stats = {}
    @stat_profile = { names:[], tables: {}, joins: {}, platforms:[], events_tables: {} }

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

    interval = obj['interval'] rescue _default_interval;

    #@details[name] = { name: name, sql_raw: sql }
    STDERR.puts "analyzing #{name}"

    cmd="./bin/sqlfmt -s ./data/schema_3.3.1.csv -j \"#{sql}\""
    ##puts "CMD:#{cmd}"
    tmp=`#{cmd}` ### `./bin/sqlfmt -s ./data/schema_3.3.1.csv -j "#{sql}"`
    ##puts "tmp:#{tmp}"


    result = JSON.parse(tmp) rescue nil

    if (result.nil? or result['sql_raw'].nil?)
      STDERR.puts "ERROR analyzing query '#{name}'"
      #exit 3
      result = { 'table' => '?' , 'joins' => {} }
      result['name'] = name
      result['interval'] = interval
      result['platform'] = obj['platform']
      @details[name] = result

      return
    end

    # fill in details

    result['name'] = name
    result['interval'] = interval
    result['platform'] = obj['platform']
    @details[name] = result

    #puts result.inspect
    #exit 3
  end

  def track_ref_count(count_map, strval)
    if count_map[strval].nil?
      count_map[strval] = 1
    else
      count_map[strval] += 1
    end
  end

  def add_unique(a, strval)
    unless a.include?(strval)
      a.push strval
    end
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

      # update platforms stats
      if @platforms[obj['platform']].nil?
        @platforms[obj['platform']] = 1
      else
        @platforms[obj['platform']] += 1
      end

      # update map of table to queries
      if @table_queries[obj['table']].nil?
        @table_queries[obj['table']] = { queries:[], joins:[] }
      end
      @table_queries[obj['table']][:queries].push obj['name']


      obj['joins'].each do |talias, fields|
        stat[:joins].push fields['table_name']
        track_ref_count @stat_profile[:joins], fields['table_name']

        @table_queries[obj['table']][:joins].push obj['name']
      end
      #puts "[#{ival}] = #{JSON.generate(stat)}"
      @interval_stats[ival].push stat


      # stat_profile tables

      if obj['table'].include?('_events')
        track_ref_count @stat_profile[:events_tables], obj['table']
      else
        track_ref_count @stat_profile[:tables], obj['table']
      end

      @stat_profile[:names].push obj['name']
      add_unique @stat_profile[:platforms], obj['platform'] if obj['platform']

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

`mkdir -p ./out/c/`
`mkdir -p ./out/usage/` # queries_for_<interval>.htm and table_usage_<table_name>.htm

ARGV.each do |filepath|

  File.open(filepath) do |f|

    if filepath.end_with?('.flags')
      checker.load_flags f.readlines
      next
    end

    obj = JSON.parse(f.read)
    if obj.nil?
      STDERR.puts "ERROR reading file:#{filepath}"
      next
    end

    # add config file to list
    # write out config file in JSON pretty format

    filename = File.basename filepath
    checker.config_files.push filename
    File.open("out/c/#{filename}",'w') do |f|
      f.puts JSON.pretty_generate obj
    end

    checker.load_options(obj['options'])

    _default_interval = @options['interval'] rescue 3600

    checker.load_sched(obj['queries'])
    checker.load_sched(obj['schedule'])
    checker.load_packs(obj['packs'])

  end
end



  checker.build_interval_stats

  checker.stat_profile[:names].sort!

  File.open('out/stats.js','w') do |f|
    f.puts "var interval_stats=#{JSON.generate checker.interval_stats};"
    f.puts "var stats_profile=#{JSON.generate checker.stat_profile};"
    f.puts "var table_queries=#{JSON.generate checker.table_queries};"
    f.puts "var config_sources=#{JSON.generate checker.table_queries};"
    f.puts "var platforms=#{JSON.generate checker.platforms};"
  end

  # dump out a file for each query - pretty printed details

  #Dir.mkdir('./q/');
  `mkdir -p ./out/q/`

  checker.details.each do |name, detail|
    File.open("out/q/#{name}.htm",'w') do |f|
      f.puts "<html><head><title>Query : #{name}</title>"
      f.puts "  <script src='https://code.jquery.com/jquery-3.3.1.min.js'></script>"
      f.puts "  <script src='../querydetail.js' type='text/javascript'></script>"
      f.puts "<link href=\"../sqlstyle.css\" rel=\"stylesheet\" type=\"text/css\" />"
      f.puts "</head><body>"

      f.puts "<div><b>Name</b>:#{name}<BR><b>Interval</b>:#{detail['interval']}<BR></div>"

      unless detail['columns'].nil?
        f.puts "<h4>Columns:</h4>"

        f.puts "<table class='greyGridTable' style='margin:10px'><tr><th>Column Label</th><th>Source</th><th>Type</th><th>Notes</th></tr>"
        detail['columns'].each do |col|
          source_name = ""
          unless col['source_column'].nil?
            source_name = col['source_table'] + "." + col['source_column']
          end
          f.puts "<tr><td><B>#{col['label']}</B></td><td>#{source_name}</td><td>#{col['type']}</td><td>#{col['notes']}</td></tr>"
        end
        f.puts "</table>"
      end


      unless detail['sql_htm'].nil?
        f.puts "<h4>SQL:</h4>"
        f.puts "<div class=\"stmt\" style='display:inline-block;padding:5px;border:1px solid #AAA'>#{detail['sql_htm']}</div>"
      else
        f.puts "<HR>"
      end

      f.puts "<h4>Raw SQL:</h4>"
      f.puts "<div class='stmt'>#{detail['sql_raw']}</div>"

      f.puts "</div></html>"
    end

    # TODO: copy if not exists
    #FileUtils.cp('./pages/_interval_summary.js', './out/interval_summary.js')
    #FileUtils.cp('./pages/_intervals.html', './out/intervals.html')

    # queries per interval
    checker.interval_stats.each do |interval, items|
      File.open("out/usage/queries_for_#{interval}.htm",'w') do |f|
        f.puts "<html><head><title>Queries for Interval #{interval}</title>"
        f.puts "<link href=\"../intervalstyle.css\" rel=\"stylesheet\" type=\"text/css\" />"
        f.puts "</head><body>"

        f.puts "<div><b>Interval</b>:#{detail['interval']}<BR></div>"

        names = []

        items.each do |item|
          names.push item[:name]
        end
        names.sort!
        names.each do |name|
          f.puts "<div><a href='../q/#{name}.htm'>#{name}</a></div>"
        end
        f.puts "</body></html>"
      end
    end

    # queries per table
    # table_name => { queries: [], joins: []}
    checker.table_queries.each do |table_name, obj|
      File.open("out/usage/table_usage_#{table_name}.htm",'w') do |f|
        f.puts "<html><head><title>Table Usage: #{table_name}</title>"
        f.puts "<link href=\"../intervalstyle.css\" rel=\"stylesheet\" type=\"text/css\" />"
        f.puts "</head><body>"

        f.puts "<div><b>Table</b>:#{table_name}<BR></div>"

        obj[:queries].each do |query_name|
          f.puts "<div><a href='../q/#{query_name}.htm'>#{query_name}</a></div>"
        end
        f.puts "</body></html>"
      end
    end

  end

#checker.report
