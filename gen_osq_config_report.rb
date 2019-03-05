#!/usr/bin/ruby

require 'json'
require 'digest'
require 'fileutils'
require 'date'

class Checker
  attr_accessor :queries, :packs, :options, :errors, :warnings, :details
  attr_accessor :interval_stats, :interval_stats_events
  attr_accessor :stat_profile, :config_files, :table_queries, :platforms

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
    @interval_stats_events = {}
    @stat_profile = { names:[], tables: {}, joins: {}, platforms:[], events_tables: {} }

    @prettycmd = "/usr/local/bin/prettysql"
    @prettycmd = "./bin/prettysql" if File.exists? "./bin/prettysql"

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

    cmd="#{@prettycmd} -s ./data/schema_3.3.1.csv -j \"#{sql}\""
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
      result['sql_raw'] = sql
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

  def push_map dest, key, value
    if dest[key].nil?
      dest[key] = []
    end
    dest[key].push value

  end

  #-------------------------------------------------------------
  # build interval stats
  #-------------------------------------------------------------
  def build_interval_stats
    @interval_stats = {}
    @interval_stats_events = {}

    @details.each do |name, obj|
      #puts "#{name} #{ival}"
      ival = obj['interval'].to_i

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

      push_map @interval_stats, ival, stat
      push_map @interval_stats_events, ival, stat if name.include?('_events') && name != 'osquery_events'

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

def copy_unless_exists(name, destdir)
  src = "./pages/_#{name}"
  dest = "./out/#{destdir}/#{name}"

  return if File.exists?(dest)

  FileUtils.cp(src, dest)
end

def write_stats_js checker, destdir
  File.open("./out/#{destdir}/stats.js",'w') do |f|
    f.puts "var interval_stats=#{JSON.generate checker.interval_stats};"
    f.puts "var interval_stats_events=#{JSON.generate checker.interval_stats_events};"
    f.puts "var stats_profile=#{JSON.generate checker.stat_profile};"
    f.puts "var table_queries=#{JSON.generate checker.table_queries};"
    f.puts "var config_sources=#{JSON.generate checker.config_files};" # remove: only one per dir now
    f.puts "var platforms=#{JSON.generate checker.platforms};"
  end
end

def write_stats_cache checker, destdir
  `mkdir ./cache` unless Dir.exists?('./cache')
  File.open("./cache/#{destdir}_data.json",'w') do |f|
    obj = { interval_stats: checker.interval_stats,
      interval_stats_events: checker.interval_stats_events,
      stat_profile: checker.stat_profile,
      table_queries: checker.table_queries,
      platforms: checker.platforms, details: checker.details }
    f.puts JSON.generate obj
  end
end

def read_stats_cache checker, destdir
  data = JSON.parse("./cache/#{destdir}/_data.json")
  return true if data.nil? || data.details.nil? || data.details.empty?

  checker.details = data.details
  checker.interval_stats = data.interval_stats
  checker.interval_stats_events = data.interval_stats_events
  checker.stat_profile = data.stat_profile
  checker.table_queries = data.table_queries
  checker.platforms = data.platforms

  return false
end

#-------------------------------------------------------------------
# remove any path separators from query name
#-------------------------------------------------------------------
def query_name_to_filename(query_name)
  return query_name.chomp().gsub('/','_').gsub("\\",'_')
end

#-------------------------------------------------------------------
#-------------------------------------------------------------------
def write_query_detail name, detail, destdir, config_file_name
  File.open("./out/#{destdir}/q/#{query_name_to_filename name}.htm",'w') do |f|
    f.puts "<html><head><title>Query : #{name}</title>"
    f.puts "  <script src='https://code.jquery.com/jquery-3.3.1.min.js'></script>"
    f.puts "  <script src='../querydetail.js' type='text/javascript'></script>"
    f.puts "<link href=\"../style.css\" rel=\"stylesheet\" type=\"text/css\" />"
    f.puts "</head><body>"

    f.puts "<div><b>Name</b>:#{name}<BR><b>Config</b>:#{config_file_name}<BR><b>Interval</b>:#{detail['interval']}<BR></div>"

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
end

def write_queries_per_interval interval_stats, destdir
  # queries per interval
  interval_stats.each do |interval, items|
    File.open("out/#{destdir}/usage/queries_for_#{interval}.htm",'w') do |f|
      f.puts "<html><head><title>Queries for Interval #{interval}</title>"
      f.puts "<link href=\"../style.css\" rel=\"stylesheet\" type=\"text/css\" />"
      f.puts "</head><body>"

      f.puts "<div><b>Interval</b>:#{interval}<BR></div>"

      names = []

      items.each do |item|
        names.push item[:name]
      end
      names.sort!
      names.each do |name|
        f.puts "<div><a href='../q/#{query_name_to_filename name}.htm'>#{name}</a></div>"
      end
      f.puts "</body></html>"
    end
  end
end

def write_queries_per_table table_queries, destdir
  # table_name => { queries: [], joins: []}
  table_queries.each do |table_name, obj|
    File.open("out/#{destdir}/usage/table_usage_#{table_name}.htm",'w') do |f|
      f.puts "<html><head><title>Table Usage: #{table_name}</title>"
      f.puts "<link href=\"../style.css\" rel=\"stylesheet\" type=\"text/css\" />"
      f.puts "</head><body>"

      f.puts "<div><b>Table</b>:#{table_name}<BR></div>"

      obj[:queries].each do |query_name|
        f.puts "<div><a href='../q/#{query_name_to_filename query_name}.htm'>#{query_name}</a></div>"
      end
      f.puts "</body></html>"
    end
  end
end

# Some of the pack conf files have invalid JSON
# with line-continuation backslash line-endings.
# This function will remove the backslashes and
# join the two lines.
# Example input we are targetting:
#
#      "query" : "select * from launchd where \
#        name = 'com.apple.machook_damon.plist' OR \
#        name = 'com.apple.periodic-dd-mm-yy.plist';",
def remove_line_continuations(raw_json)
  return raw_json.gsub("\\\n", "")
end

flag_use_cached_stats = false
dirs = []
ARGV.each do |filepath|

  File.open(filepath) do |f|

    checker = Checker.new
    destdir="placeholder"

    if filepath.end_with?('.flags')
      checker.load_flags f.readlines
      next
    end

    obj = JSON.parse(remove_line_continuations f.read)
    if obj.nil?
      STDERR.puts "ERROR reading file:#{filepath}"
      next
    end

    # add config file to list
    # write out config file in JSON pretty format

    filename = File.basename filepath
    destdir = filename.gsub ".*",""
    dirs.push destdir

    `mkdir -p ./out/#{destdir}/c/`
    `mkdir -p ./out/#{destdir}/usage/` # queries_for_<interval>.htm and table_usage_<table_name>.htm

    checker.config_files.push filename

    if flag_use_cached_stats
      if read_stats_cache checker, destdir
        STDERR.puts "ERROR loading stats cache for #{destdir}"
        exit 3
      end
    else
      File.open("out/#{destdir}/c/#{filename}",'w') do |f|
        f.puts JSON.pretty_generate obj
      end

      checker.load_options(obj['options'])

      _default_interval = @options['interval'] rescue 3600

      checker.load_sched(obj['queries'])
      checker.load_sched(obj['schedule'])
      checker.load_packs(obj['packs'])

      checker.build_interval_stats
      checker.stat_profile[:names].sort!

      # details, interval_stats, table_queries, stat_profile
      write_stats_cache checker, destdir
    end

    write_stats_js checker, destdir

    # dump out a file for each query - pretty printed details

    `mkdir -p "./out/#{destdir}/q/"`

    checker.details.each do |name, detail|
      write_query_detail name, detail, destdir, filename
    end

    # copy files - if_exists allows for using symlinks in development

    copy_unless_exists('interval_summary.js', destdir)
    copy_unless_exists('index.html', destdir)
    copy_unless_exists('style.css', destdir)
    copy_unless_exists('querydetail.js', destdir)

    write_queries_per_interval checker.interval_stats, destdir
    write_queries_per_table checker.table_queries, destdir

  end # end file
end # each file

# write index.html with links to each config file processed

File.open("./out/index.html",'w') do |f|
  f.puts "<html><style type='text/css'>"
  f.puts "body{font-size:12pt;} a:any-link { color:black; text-decoration: none; }"
  f.puts "a:hover {      color:blue;      text-decoration: underline;    }"
  f.puts "</style><body>"
  f.puts "Date: #{Time.now.strftime("%Y-%m-%d %H:%M:%S")}"
  f.puts "<ul>"
  dirs.each do |destdir|
    f.puts "<li><a href='#{destdir}/index.html'>#{destdir}</a>"
  end
  f.puts "</ul></body></html>"
end
