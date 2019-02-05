function calcAndRender() {
  var schedulePoints = [];
  var packPoints = [];

  // chart params

  var tEnd = 60*60;
  var numTicks = 60;

  // break into ticks

  var tickSeconds = Math.round(tEnd / numTicks);
  console.log({tickSeconds: tickSeconds});

  // initialize

  var j = 0;
  for (var key in interval_stats) {
    var ival = parseInt(key);
    j++;

    var numIntervalTicks = Math.min(Math.floor(tEnd / ival), numTicks);
    var numIntervals = Math.max(1, Math.round((tickSeconds + 0.0) / ival));

    //console.log({ival:ival, numIntervalTicks: numIntervalTicks, numIntervals: numIntervals});

    var step = 0;
    if (numIntervalTicks > 0) { step = (0.0 + numTicks) / numIntervalTicks; }
    var numQueriesForInterval = interval_stats[key].length;

    for (var i=0; i <= numIntervalTicks; i++) {
      var radius = 5 + Math.round(numQueriesForInterval / 5);
      var alpha = '0.' + (6 + Math.round(numIntervals / 2));
      var color = 'rgba(99, 132, 191,' + alpha + ')';

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
        schedulePoints.push(point);
        break;
      }

      schedulePoints.push(point);
    }
  }

  renderIntervalChart('ichart', schedulePoints, packPoints);
}

function timeFmt(value) {
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

function renderIntervalChart(element, schedulePoints, packPoints) {
  Highcharts.chart(element, {
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
      series: [{
          name: 'Schedule',
          color: 'rgba(119, 152, 191, .5)',
          data: schedulePoints,
          dataLabels: { enabled: true, color:'#888', inside: true, format: '{point.numQueries}'}
        }, {
          name: 'Packs',
          color: 'rgba(223, 83, 83, .5)',
          data: packPoints
      }]
  });
}
