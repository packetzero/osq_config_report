//------------------------------------------------------
// return string like:
// value: 5400 return: '1h 30m'
// value: 300  return: '5m'
// value: 60   return: '1m'
// value: 90   return: '1m 30s'
//------------------------------------------------------
function timeFmt(value /* seconds */) {
  var hrs = Math.floor(value / 3600);
  var mins =  Math.floor((value % 3600 )/ 60);
  var secs = value % 60;
  var s = "";
  if (hrs > 0) {
    s += hrs + "h ";
    s += mins + "m";
  } else {
    s += mins + "m";
    if (secs > 0) { s += " " + secs + "s"; }
  }
  return s;
}

var seriesColors = [ 'rgba(119, 152, 191, .5)', 'rgba(223, 83, 83, .5)', 'rgba(0, 83, 83, .5)', 'yellow', 'purple'];

var params = {
  tables: true, // ['some_table']
  platforms: true,
  packs: true,
  showEvents: true,
};

var dataValues = {
  names: [],
  tables:{},
  joins: {},
  events_tables: {},
  platforms: [],
  packs: [],
};

// chart params

var tEnd = 60*60;
var numTicks = 60;

// break into ticks

var tickSeconds = Math.round(tEnd / numTicks);

//------------------------------------------------------
// Increment intval for key strval, or create = 1
// obj = {
//   'something' : 23,
//   'something_else' : 1
// }
//------------------------------------------------------
function trackRefCount(obj, strval) {
  if (obj[strval]) {
    obj[strval]++;
  } else {
    obj[strval] = 1;
  }
}

function addToArrayUnique(a, strval)
{
  for (var i=0; i < a.length; i++) {
    if (a[i] == strval) {
      return;
    }
  }
  a.push(strval);
}

//------------------------------------------------------
//------------------------------------------------------
function profileData(interval_stats)
{
  for (var key in interval_stats) {
    var ival = parseInt(key);

    for (var i=0; i < interval_stats[key].length; i++) {
      var rec = interval_stats[key][i];

      // add name

      dataValues.names.push(rec.name);
      var platform = (rec.platform ? rec.platform : 'All');
      addToArrayUnique(dataValues.platforms, platform);

      // add table

      if (rec.table.indexOf('_events') > 0) {
        trackRefCount(dataValues.events_tables, rec.table);
      } else {
        trackRefCount(dataValues.tables, rec.table);
      }

      // add joins

      if (rec['joins']) {
        for (var j=0; j < rec.joins.length; j++) {
          trackRefCount(dataValues.joins, rec.joins[j]);
        }
      }

      // pack?
      if (rec['pack']) {
        addToArrayUnique(rec.packs, rec['pack']);
      }
    } // for each record
  } // for each interval

  console.log(dataValues);
}

//------------------------------------------------------
//
//{
//  "name": "detection_windows_netcat_listening",
//  "table": "processes",
//  "joins": [
//    "authenticode",
//    "file",
//    "process_open_sockets"
//  ],
//  "platform": null
//}
//------------------------------------------------------
function getAssignedSeries(rec)
{
  //if ()
}

function compare_num_desc(a,b) {
  return b.num - a.num;
}

function renderProfileStats(profile_stats)
{
  var s='';
  for (var i=0; i < profile_stats['names'].length; i++) {
    var name = profile_stats['names'][i];
    s += "<a href='./q/" + name + ".htm'>" + name + "</a><BR>";
  }
  jQuery('div.DivQueries').append(s);

  // build sorted array of queries and joins per table
  var data = [];
  for (var table_name in table_queries) {
    var item = table_queries[table_name];
    data.push({name:table_name, num: item['queries'].length, joins: item['joins'].length});
  }
  data.sort(compare_num_desc);

  // display of queries and joins per table
  s='<table class="greyGridTable">';
  s+='<tr><th>Queries</th><th>Joins</th><th>Table</th></tr>';
  for (var i=0;i < data.length; i++) {
    var item = data[i];
    s += "<tr><td>" + item.num + "</td><td>" + item.joins;
    s += "</td><td><a href='./usage/table_usage_";
    s += item.name + ".htm'";
    if (item.name.indexOf('_events') > 0 && item.name != 'osquery_events') {
      s += " class='EventTable' ";
    }
    s += ">" + item.name + "</a></td></tr>";
  }
  s += "</table>";
  jQuery('div.DivTables').append(s);
}

function renderConfigSources(config_files)
{
  var s='';
  for (var i=0; i < config_files.length; i++) {//name in profile_stats['names']) {
    var name = config_files[i];
    s += "<a href='./c/" + name + "'>" + name + "</a><BR>";
  }
  jQuery('div.ConfigSources').append(s);
}

function buildSeries(stats, numTicks, tickSeconds, colorPrefix='rgba(99, 132, 191,')
{
  var points = [];

    var j = 0;
    for (var key in stats) {
      var ival = parseInt(key);
      j++;

      var numIntervalTicks = Math.min(Math.floor(tEnd / ival), numTicks);
      var numIntervals = Math.max(1, Math.round((tickSeconds + 0.0) / ival));

      //console.log({ival:ival, numIntervalTicks: numIntervalTicks, numIntervals: numIntervals});

      var step = 0;
      if (numIntervalTicks > 0) { step = (0.0 + numTicks) / numIntervalTicks; }
      var numQueriesForInterval = stats[key].length;

      for (var i=0; i <= numIntervalTicks; i++) {
        var radius = 5 + Math.round(numQueriesForInterval / 5);
        var alpha = '0.' + (6 + Math.round(numIntervals / 2));
        var color = colorPrefix + alpha + ')';

        var point = { x: Math.round(i * tickSeconds * step), y: j * 3 ,
          numIntervals: numIntervals,
          interval: ival,
          intervalStr: timeFmt(ival),
          numQueries: numQueriesForInterval,
          marker: { radius : radius, fillColor: color }
        };

        if (numIntervalTicks == 0) {
          // points outside the window should be gray at t=0
          point.marker.fillColor = 'rgba(128,128,128,0.5)';
          points.push(point);
          break;
        }

        points.push(point);
      }
    }
    return points;
}

//------------------------------------------------------
//
//------------------------------------------------------
function calcAndRender() {

  renderConfigSources(config_sources); // stats.js
  renderProfileStats(stats_profile); // stats.js

  console.log({tickSeconds: tickSeconds});

  var datas = [
    { name:"Schedule Table Queries", points: buildSeries(interval_stats, numTicks, tickSeconds)}
    ,{ name:"Schedule Events Queries", points: buildSeries(interval_stats_events, numTicks, tickSeconds, 'rgba(153, 0, 0,')}
  ];

  renderIntervalChart('ichart', datas);
}



function renderIntervalChart(element, datas) {
  var opts = {
      chart: {
          type: 'scatter',
          zoomType: 'xy'
      },
      title: {
          text: 'Intervals in Schedule'
      },
      xAxis: {
          title: {
              enabled: true,
              text: 'Time (seconds)'
          },
          startOnTick: true,
          endOnTick: true,
          showLastLabel: true,
          tickInterval: 300,
          labels: {
            formatter: function() { return timeFmt(this.value); }
          }
      },
      yAxis: {
        enabled: false,
        visible:false,
          title: {
              text: ''
          }
      },
      legend: {
        enabled:false,
        visible:false,
          layout: 'vertical',
          ffalign: 'left',
          ffverticalAlign: 'top',
          ffx: 100,
          ffy: 70,
          xxfloating: true,
          backgroundColor: (Highcharts.theme && Highcharts.theme.legendBackgroundColor) || '#FFFFFF',
          borderWidth: 1
      },
      plotOptions: {
          scatter: {
              marker: {
                  radius: 5,
                  states: {
                      hover: {
                          enabled: true,
                          lineColor: 'rgb(100,100,100)'
                      }
                  }
              },
              states: {
                  hover: {
                      marker: {
                          enabled: false
                      }
                  }
              },
              tooltip: {
                  headerFormat: '<b>{series.name}</b><br>',
                  pointFormat: 'interval_length:{point.intervalStr}, queries:{point.numQueries}, num_intervals:{point.numIntervals}'
              }
          }
      },
      series: []
  };

  // add series data

  for (var i=0; i < datas.length; i++) {
    var data = datas[i];
    opts.series.push({
        name: data.name,
        color: seriesColors[i],
        data: data.points,
        dataLabels: { enabled: true, color:'#888', inside: true, format: '{point.numQueries}'},
        events: {
          click: function(evt) {
            var url = './usage/queries_for_' + evt.point.interval + '.htm';
            console.log(url);
            window.location = url;
          }
        }
      });
  }

  // pass to highcharts

  Highcharts.chart(element, opts);
}
