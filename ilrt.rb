#!/usr/bin/ruby
#
# Instrumentation Log Report Tool for IBM BPM
# (c)2014 andy.fedotov@gmail.com
#

require 'pp'
require 'time'
require 'optparse'

$INST_FILENAME = nil
$PRINT_PROFILE = false
$PRINT_TOP_SELF_PERIODS = false
$DUMP_EXPENSIVE = false
$MAX_DEPTH = nil
$USE_CACHE = true
$TOP_THREADS_COUNT = 10

$INST = {
    :threads => [],
    :cache => {},
    :firstTimestamp => nil,
    :lastTimestamp => nil,
    :totalDuration => nil
}
$currentThread = nil

OptionParser.new do |o|
  o.on('-f', '--file PATH', 'IBM BPM Instrumentation Log File (txt format)') { |v| $INST_FILENAME = v }
  o.on('-t', '--top COUNT', 'Number of Expensive Activities to print, default = ' + $TOP_THREADS_COUNT.to_s) { |n| $TOP_THREADS_COUNT = n.to_i }
  o.on('-p', '--prof', 'Print Expensive Activities detailed profile') { $PRINT_PROFILE = true }
  o.on('-l', '--level N', 'Expensive Activities detailed profile maximum depth level') { |v| $MAX_DEPTH = v.to_i  }
  o.on('-s', '--self', 'Print top self periods') { $PRINT_TOP_SELF_PERIODS = true }
  o.on('-d', '--dump', 'Dump each Expensive Activity raw log to separate file') { $DUMP_EXPENSIVE = true }
  o.on('-r', '--rescan', 'Do not use cached index and forcibly rescan instrumentation log file') { $USE_CACHE = false }
  o.on('-h', '--help', 'Print help') { puts o; exit! }
  o.parse!
  if $INST_FILENAME.nil?
    puts 'Instrumentation Log Report Tool for IBM BPM'
    puts o
    exit!
  end
end

###########################################################################################

def createOutputFilename(t)
  filename = (t[:name]+'.'+t[:startLine].to_s).split(/(?<=.)\.(?=[^.])(?!.*\.[^.])/m).map! { |s| s.gsub /[^a-z0-9\-]+/i, '_' }.join('.')
  return File.dirname($INST_FILENAME) + '/' + $INST_FILENAME + '.' + filename + '.thread.txt'
end

def resetProgress
  $prev_pt = nil
end

def printProgress(current, max)
  current_pt = current * 100 / max
  if $prev_pt.nil? || current_pt - $prev_pt >= 1
    print "\b" * 4 unless $prev_pt.nil?
    print '= %02d%%' % current_pt
  end
  $prev_pt = current_pt
end

def parseTimestamp(ts)
  return Time.parse('2014-01-01 '+ts)
end

def median(array)
  sorted = array.sort
  len = sorted.length
  return (sorted[(len - 1) / 2] + sorted[len / 2]) / 2.0
end

def recordSelfPeriod(ts)
  t = parseTimestamp(ts)
  if !$currentThread[:last_ts].nil? && (t-$currentThread[:last_ts])*1000 > 0
    sp = {
        :timestamp => $currentThread[:last_ts],
        :duration => ((t-$currentThread[:last_ts])*1000).to_i,
        :name => '#self#',
        :details => '',
        :nested => []
    }
    $currentThread[:periods_tree].last << sp
    $currentThread[:self_periods] << sp
  end
  $currentThread[:last_ts] = parseTimestamp(ts)
end

def processLine(ts, line)
  if / (\s*)period\s+(\d+ms|\(incomplete\))\s+'(.*?)'(.*)\{/.match(line)
    recordSelfPeriod(ts)
    $currentThread[:incomplete] = true if $2.include?('incomplete')
    lvl = ($1.length / 3).to_i
    p = {
        :timestamp => parseTimestamp(ts),
        :duration => $2.to_i,
        :name => $3.strip,
        :details => $4.strip,
        :nested => []
    }
    $currentThread[:periods][lvl] = [] if $currentThread[:periods][lvl].nil?
    $currentThread[:periods][lvl] << p
    $currentThread[:periods_tree].last << p
    $currentThread[:periods_tree].push(p[:nested])
  elsif /^ (\s*)\}\s*$/.match(line)
    recordSelfPeriod(ts)
    $currentThread[:periods_tree].pop()
  end
  if /.*?point\s+'Cache (.+?)'\s+dbId=(.+?)\s+type=(.+)\s*$/.match(line)
    $INST[:cache][$3] = {} if $INST[:cache][$3].nil?
    $INST[:cache][$3][$2] = {} if $INST[:cache][$3][$2].nil?
    $INST[:cache][$3][$2][$1] = 0 if $INST[:cache][$3][$2][$1].nil?
    $INST[:cache][$3][$2][$1] += 1
  end
end

def printHeader(f)
  f.puts '=' * 155
  f.puts "\n Report generated with Instrumentation Log Report Tool for IBM BPM"
  f.puts ' (c)2014 andy.fedotov@gmail.com'
  f.puts "\n"
  f.puts ' Instrumentation log started at : ' + $INST[:firstTimestamp].strftime('%H:%M:%S.%3N')
  f.puts ' Instrumentation log ended at   : ' + $INST[:lastTimestamp].strftime('%H:%M:%S.%3N')
  f.puts ' Recording duration (secs)      : ' + $INST[:totalDuration].to_s
  f.puts ' Report Generated on            : ' + Time.now.to_s + "\n\n"
  f.puts '=' * 155
  f.puts "\n"
end

def printExpensiveThreadProfile(f, periods, level)
  return unless $MAX_DEPTH.nil? || level < $MAX_DEPTH
  if periods.size > 0
    p = periods.group_by{ |i| i[:name] + (i[:details].empty? ? "" : ", "+i[:details]) }
    return if p.keys.size == 1 && p.keys.first == '#self#'
    p.keys.sort { |a, b| p[b].map{ |v| v[:duration] }.reduce(:+) <=> p[a].map{ |v| v[:duration] }.reduce(:+) }.each { |k|
      durations = p[k].map{ |v| v[:duration] || 0 }
      total = durations.reduce(:+)
      count = p[k].size
      median = median(durations).round
      max = durations.max
      f.puts '|    '*level + '%d ms - %s [cnt=%d,med=%dms,max=%dms]' % [total, k, count, median, max]
      nested = p[k].map{ |v| v[:nested] }.flatten
      printExpensiveThreadProfile(f, nested, level+1)
    }
  end
end

def printTopSelfPeriods(f, sp, count)
  f.puts '-'*50
  f.puts '| %-27s | %16s |' % ['Start/End time','Duration (ms)']
  f.puts '-'*50
  sp.sort { |a,b| b[:duration] <=> a[:duration]}.take(count).each do |p|
    f.puts '| %-12s - %-12s | %16s |' % [p[:timestamp].strftime('%H:%M:%S.%3N'), (p[:timestamp] + p[:duration].to_f/1000).strftime('%H:%M:%S.%3N'), p[:duration]]
  end
  f.puts '-'*50
end

def printPeriodsLevelBreakdown(f, periods)
  f.puts '| %-8s | %-8s | %-8s | %-8s | %-8s | %-96s |' % ['Total', 'Average', 'Median', 'Max', 'Count', 'Details']
  f.puts '-' * 155
  if periods.nil? || periods.size == 0
    f.puts '| %-8s | %-8s | %-8s | %-8s | %-8s | %-96s |' % ['-', '-', '-' ,'-', '-', '-' ]
  else
    periods = periods.group_by{ |i| i[:name] + (i[:details].empty? ? '' : ', '+i[:details]) }
    periods.keys.sort { |a, b| periods[b].map{ |v| v[:duration] }.reduce(:+) <=> periods[a].map{ |v| v[:duration] }.reduce(:+) }.each { |k|
      durations = periods[k].map{ |v| v[:duration] || 0 }
      total = durations.reduce(:+)
      count = periods[k].size
      average = (total.to_f/count).round
      median = median(durations).round
      max = durations.max.to_i
      f.puts '| %-8s | %-8s | %-8s | %-8s | %-8s | %-96s |' % [total, average, median, max ,count, k ]
    }
  end
end

def printExpensiveThreadsDetails(f, for_name, expensiveThreads)
  f.puts "==> Top #{$TOP_THREADS_COUNT} Expensive Activities: Details for " + for_name + "\n\n"
  expensiveThreads.each { |t|
    f.puts '-' * 155
    f.puts '| %-12s | %-136s |' % [t[:duration].to_s + ' ms' , 'ActivityID = ' + t[:startLine].to_s + ', Thread Name = ' + t[:name]]
    f.puts '-' * 155
    t[:periods].keys.sort.each do |lvl|
      next unless $MAX_DEPTH.nil? || lvl < $MAX_DEPTH
      periods = t[:periods][lvl]
      f.puts '| %-151s |' % ["L#{lvl+1} periods breakdown, total recorded duration = " + (periods || []).map{|p| p[:duration]}.reduce(:+).to_i.to_s+' ms']
      f.puts '-' * 155
      printPeriodsLevelBreakdown(f, periods)
      f.puts '-' * 155
    end
    f.puts "\n"
    f.puts 'Detailed profile for ActivityID = ' + t[:startLine].to_s + ', Thread Name = ' + t[:name]
    f.puts "\n"
    printExpensiveThreadProfile(f, t[:periods_tree].first, 0)
    f.puts "\n"
    if $PRINT_TOP_SELF_PERIODS
      f.puts 'Top 10 of self periods for ActivityID = ' + t[:startLine].to_s + ', Thread Name = ' + t[:name]
      f.puts "\n"
      printTopSelfPeriods(f, t[:self_periods], 10)
      f.puts "\n"
    end
    f.puts '*' * 155
    f.puts "\n"
  }
end

def printExpensiveThreads(f, for_name, count)
  expensive = $INST[:threads]
                .select { |t| t[:name].start_with?(for_name) }
                .sort! { |a,b| b[:duration] <=> a[:duration] }
                .take(count)
  f.puts "==> Top #{count} Expensive Activities: Overview for " + for_name + "\n\n"
  f.puts '-' * 130
  f.puts '| %-16s | %-32s | %-12s | %-12s | %-12s | %-12s | %-12s |' % ['Duration (ms)', 'Thread Name', 'ActivityID', 'L1 Periods', 'L1 Time (ms)', 'L2 Periods', 'L2 Time (ms)']
  f.puts '-' * 130
  expensive.each { |t|
    f.puts '| %-16s | %-32s | %-12s | %-12s | %-12s | %-12s | %-12s |' %
             [  t[:duration].to_s,
                t[:name],
                t[:startLine],
                (t[:periods][0] || []).size.to_s,
                (t[:periods][0] || []).map { |t| t[:duration] }.reduce(:+).to_s,
                (t[:periods][1] || []).size.to_s,
                (t[:periods][1] || []).map { |t| t[:duration] }.reduce(:+).to_s,
             ]
  }
  f.puts '-' * 130
  f.puts "\n"
  return expensive
end

def printCache(f, count)
  c = $INST[:cache]
  c = c.keys.map { |t| c[t].keys.map { |id| [t,id,c[t][id]['Hits'],c[t][id]['Misses'],c[t][id]['Bypasses']] } }.flatten(1)
  f.puts "==> Cache Statistics: Summary by persistent object type\n\n"
  f.puts '-' * 93
  f.puts '| %-32s | %-16s | %-16s | %-16s |' % ['Object type', 'Cache Misses', 'Cache Bypasses', 'Cache Hits']
  f.puts '-' * 93
  c.group_by{ |i| i[0] }.map{ |e| [ e[0], e[1].map{ |e| e[2].to_i }.reduce(:+),e[1].map{ |e| e[3].to_i }.reduce(:+),e[1].map{ |e| e[4].to_i }.reduce(:+)] }.sort{ |a,b| b[2] <=> a[2] }.each do |r|
    f.puts '| %-32s | %-16s | %-16s | %-16s |' % [r[0], r[2], r[3], r[1]]
  end
  f.puts '-' * 93
  f.puts '| %-32s | %-16s | %-16s | %-16s |' % ['- Total -', c.map{ |e| e[3].to_i }.reduce(:+), c.map{ |e| e[4].to_i }.reduce(:+), c.map{ |e| e[2].to_i }.reduce(:+)]
  f.puts '-' * 93
  f.puts '| %-32s | %-54.3f |' % ['Wasting DB, transactions/sec', (c.map{ |e| e[3].to_i }.reduce(:+) + c.map{ |e| e[4].to_i }.reduce(:+)) / $INST[:totalDuration] ]
  f.puts '-' * 93
  f.puts "\n"
  f.puts "==> Cache Statistics: Top #{count} cache misses by persistent object instances\n\n"
  f.puts '-' * 125
  f.puts '| %-64s | %-16s | %-16s | %-16s |' % ['Object ID', 'Cache Misses', 'Cache Bypasses', 'Cache Hits']
  f.puts '-' * 125
  c.group_by{ |i| i[0]+"."+i[1] }.map{ |e| [ e[0], e[1].map{ |e| e[2].to_i }.reduce(:+),e[1].map{ |e| e[3].to_i }.reduce(:+),e[1].map{ |e| e[4].to_i }.reduce(:+)] }.sort{ |a,b| b[2] <=> a[2] }.select{ |e| e[2] > 0 }.take(count).each do |r|
    f.puts '| %-64s | %-16s | %-16s | %-16s |' % [r[0], r[2], r[3], r[1]]
  end
  f.puts '-' * 125
  f.puts "\n"
end

def printTransactionRow(f, name, periods)
  if periods.nil? || periods.empty?
    f.puts '| %-48s | %-12s | %-12s | %-12s | %-12s | %-12s | %-12s |' % [name, '-', '-', '-', '-', '-', '-']
  else
    durations = periods.map{ |e| e[:duration] || 0 }
    count = periods.size
    total = durations.reduce(:+)
    average = (total.to_f / count).round
    median = median(durations).round
    max = durations.max.to_i
    tps = count / $INST[:totalDuration]
    f.puts '| %-48s | %-12s | %-12s | %-12s | %-12s | %-12s | %-12.3f |' % [name, count, average, median, max, total, tps]
  end
end

def printTransactions(f)
  f.puts "==> System transactions summary: Key performance points\n\n"
  f.puts '-' * 142
  f.puts '| %-48s | %-12s | %-12s | %-12s | %-12s | %-12s | %-12s |' % ['Transaction name', 'Count', 'Average (ms)', 'Median (ms)', 'Max (ms)', 'Total (ms)', 'TPS']
  f.puts '-' * 142
  fp = $INST[:threads].map { |t| t[:periods].keys.map { |k| t[:periods][k].map { |p| p } } }.flatten
  printTransactionRow(f, 'Task: Resume Workflow Engine', fp.select { |p| p[:name].start_with?('Resume Workflow Engine') } )
  printTransactionRow(f, 'Task: Load Execution Context', fp.select { |p| p[:name].start_with?('Load Execution Context') } )
  printTransactionRow(f, 'Task: Save Execution Context', fp.select { |p| p[:name].start_with?('Save Execution Context') } )
  printTransactionRow(f, 'BPD: Load Execution Context', fp.select { |p| p[:name].start_with?('findByPrimaryKey') && p[:details].include?('type=BPDInstanceData') } )
  printTransactionRow(f, 'BPD: Save Execution Context', fp.select { |p| p[:name].start_with?('save') && p[:details].include?('type=BPDInstanceData') } )
  printTransactionRow(f, 'PersistenceServices (DB Access)', fp.select { |p| ['findByPrimaryKey', 'findQuietlyByPrimaryKey', 'bulkFindByPrimaryKey', 'findByFilter', 'findSingleByFilter', 'findAll', 'save'].include?(p[:name]) } )
  printTransactionRow(f, '    - findByPrimaryKey', fp.select { |p| p[:name].start_with?('findByPrimaryKey') } )
  printTransactionRow(f, '    - bulkFindByPrimaryKey', fp.select { |p| p[:name].start_with?('bulkFindByPrimaryKey') } )
  printTransactionRow(f, '    - findByFilter', fp.select { |p| p[:name].start_with?('findByFilter') } )
  printTransactionRow(f, '    - save', fp.select { |p| p[:name].start_with?('save') } )
  printTransactionRow(f, 'Do Job (Service Step Workers)', fp.select { |p| p[:name].start_with?('Do Job') } )
  printTransactionRow(f, '    - ScriptWorker', fp.select { |p| p[:name].start_with?('Do Job') && p[:details].include?('Worker=com.lombardisoftware.component.twscript.worker.ScriptWorker') } )
  printTransactionRow(f, '    - SwitchWorker', fp.select { |p| p[:name].start_with?('Do Job') && p[:details].include?('Worker=com.lombardisoftware.component.twswitch.worker.SwitchWorker') } )
  printTransactionRow(f, '    - CoachWorker', fp.select { |p| p[:name].start_with?('Do Job') && p[:details].include?('Worker=com.lombardisoftware.component.coach.worker.CoachWorker') } )
  printTransactionRow(f, '    - CoachNGWorker', fp.select { |p| p[:name].start_with?('Do Job') && p[:details].include?('Worker=com.lombardisoftware.component.coachng.worker.CoachNGWorker') } )
  printTransactionRow(f, '    - SubProcessWorker', fp.select { |p| p[:name].start_with?('Do Job') && p[:details].include?('Worker=com.lombardisoftware.component.subprocess.worker.SubProcessWorker') } )
  printTransactionRow(f, '    - ExitPointWorker', fp.select { |p| p[:name].start_with?('Do Job') && p[:details].include?('Worker=com.lombardisoftware.component.exitpoint.worker.ExitPointWorker') } )
  printTransactionRow(f, '    - JavaConnectorWorker', fp.select { |p| p[:name].start_with?('Do Job') && p[:details].include?('Worker=com.lombardisoftware.component.javaconnector.worker.JavaConnectorWorker') } )
  printTransactionRow(f, '    - WSConnectorWorker', fp.select { |p| p[:name].start_with?('Do Job') && p[:details].include?('Worker=com.lombardisoftware.component.wsconnector.worker.WSConnectorWorker') } )
  printTransactionRow(f, '    - SCAConnectorWorker', fp.select { |p| p[:name].start_with?('Do Job') && p[:details].include?('Worker=com.lombardisoftware.component.scaconnector.worker.SCAConnectorWorker') } )
  printTransactionRow(f, '    - ILOGDecisionWorker', fp.select { |p| p[:name].start_with?('Do Job') && p[:details].include?('Worker=com.lombardisoftware.component.ilogrule.worker.ILOGDecisionWorker') } )
  printTransactionRow(f, 'Eval Script', fp.select { |p| p[:name].start_with?('Eval Script') } )
  f.puts '-' * 142
  f.puts "\n"
end

def dumpExpensive(expensive)
  i = 0;
  out = nil
  t  = expensive.sort { |a,b| a[:startLine] <=> b[:startLine] }
  f = File.open($INST_FILENAME)
  print 'Dumping: '
  resetProgress()
  begin
    lnum = 0
    while line = f.readline
      lnum += 1
      printProgress(f.pos, f.size)
      break if i >= t.size
      if lnum < t[i][:startLine]
        next
      elsif out.nil?
        out = File.open(createOutputFilename(t[i]),'w')
      end
      out.puts(line) unless out.nil?
      if lnum >= t[i][:endLine]
        out.close
        out = nil
        i += 1
      end
    end
  rescue EOFError
  end
  printProgress(100, 100)
  print "\n"
end

def scanInputFile
  resetProgress()
  f = File.open($INST_FILENAME)
  lnum = 1
  begin
    while line = f.readline
      printProgress(f.pos, f.size)
      begin
        if /^>> THREAD\s+(.*?)\s+<</.match(line)
          unless $currentThread.nil? || $currentThread[:firstTimestamp].nil?
            $currentThread[:endLine] = lnum - 1
            $INST[:threads] << $currentThread
          end
          $currentThread = {
              :name => $1,
              :startLine => lnum,
              :periods => {},
              :periods_tree =>[[]],
              :self_periods => [],
              :incomplete => false
          }
        end
        if /^(\d{2}:\d{2}:\d{2}.\d{3})(.*)/.match(line)
          if $currentThread[:firstTimestamp].nil?
            $currentThread[:firstTimestamp] = $currentThread[:lastTimestamp] = $1
          else
            $currentThread[:lastTimestamp] = $1
          end
          processLine($1, $2)
        end
      rescue
        puts $!
        puts 'Scanning error, invalid line is: ' + line
        exit!
      end
      lnum += 1
    end
  rescue EOFError
    unless $currentThread.nil? || $currentThread[:firstTimestamp].nil?
      $currentThread[:endLine] = lnum - 1
      $INST[:threads] << $currentThread
    end
  end
  timestamps = $INST[:threads].map { |t| t[:periods].keys.map { |k| t[:periods][k].map { |p| p[:timestamp] } } }.flatten
  $INST[:firstTimestamp] = timestamps.min
  $INST[:lastTimestamp] = timestamps.max
  $INST[:totalDuration] = $INST[:lastTimestamp] - $INST[:firstTimestamp]
  $INST[:threads].delete_if { |t| t[:incomplete] }
  $INST[:threads].each { |t| t[:duration] = ((parseTimestamp(t[:lastTimestamp]) - parseTimestamp(t[:firstTimestamp])) * 1000).to_i }
end

###########################################################################################

if $USE_CACHE && File.exists?($INST_FILENAME+'.idx') && File.mtime($INST_FILENAME) < File.mtime($INST_FILENAME+'.idx')
  print 'Loading cached data from ' + File.absolute_path($INST_FILENAME+'.idx') + ' ... '
  File.open($INST_FILENAME+'.idx') do |f|
    $INST = Marshal.load(f)
  end
  puts 'OK'
else
  print 'Scanning: '
  scanInputFile()
  File.open($INST_FILENAME+'.idx', 'w') do |file|
    Marshal.dump($INST, file)
  end
  print "\n"
end

File.open(File.dirname($INST_FILENAME)+'/'+File.basename($INST_FILENAME, '.*')+'.report.txt', 'w') do |f|
  print 'Saving report to: ' + File.absolute_path(f.path) + ' ... '
  printHeader(f)
  printTransactions(f)
  printCache(f, 25)
  $wcExpensive = printExpensiveThreads(f, 'WebContainer', $TOP_THREADS_COUNT)
  $tpExpensive = printExpensiveThreads(f, 'ThreadPool worker', $TOP_THREADS_COUNT)
  if $PRINT_PROFILE
    printExpensiveThreadsDetails(f, 'WebContainer', $wcExpensive)
    printExpensiveThreadsDetails(f, 'ThreadPool worker', $tpExpensive)
  end
  puts 'OK'
end

dumpExpensive($wcExpensive+$tpExpensive) if $DUMP_EXPENSIVE
