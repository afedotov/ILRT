#### ILRT - What Is It?

ILRT (Instrumentation Log Report Tool) is a utility I created to help detect and diagnose performance bottlenecks of __IBM WebSphere Lombardi Edition__ / __IBM BPM__, primarily in the Lombardi (BPMN processes) runtime. Lombardi process runtime has embedded instrumentation capabilities, and can record detailed system profile of every process or service activity. It is somehow described [here](http://www-01.ibm.com/support/docview.wss?uid=swg21613989). Оutput of NonXMLDump utility provided by IBM is a human-readable but in fact is a big and raw instrumentation log which is very difficult to read and analyze by hand. ILRT parse such raw text instrumentation log and then produce report with statistical information and detailed aggregate profile of expensive activities in a much more readable form.

Example of such report output can be viewed [here](example-reports/inst001.report.txt?raw=true).

>It is very first prototype created to address some common problems, so it was written quick using __Ruby__ language. It is very helpful, works well, but not as fast as we would like. Maybe someday I'll rewrite it on something more performant, Scala for example.

#### Download

* [ilrt.rb](ilrt.rb?raw=true) - If you on the Mac OS X, or your system has Ruby interpreter installed.
* [ilrt.jar](ilrt.jar?raw=true) - It is compiled version based on JRuby, and is only required to have Java JRE to run.

For Windows systems you can download and install Ruby from here - http://rubyinstaller.org/

#### How to Run

First you should create plain text instrumentation log from binary log with [IBM provided utility](http://www-01.ibm.com/support/docview.wss?uid=swg21613989). Note that default values for `dumpIfOver` and `truncateIfOver` are 10000 and 20000, so if your activities has more than 10k periods, such activities will be splitted and truncated. For logs with big and expensive activities I use much more bigger values here, so nothing will be truncated.

```
$ NonXMLDump inst001.dat -dumpIfOver 10000000 -truncateIfOver 10000000 > inst001.txt
```

Java version. You must set value for maximum heap with __-Xmx__ option proportionally to instrumentation log size:
```
$ java -Xmx2048m -jar ilrt.jar -f inst001.txt -p
```

Ruby version:
```
$ ./ilrt.rb -f inst001.txt -p
```

After processing is completed a report will be written to the __{BASENAME}.report.txt__ file, in this case __inst001.report.txt__.

#### Other command-line options

```
Usage: ilrt [options]
    -f, --file PATH          IBM BPM Instrumentation Log File (txt format)
    -t, --top COUNT          Number of Expensive Activities to print, default = 10
    -p, --prof               Print Expensive Activities detailed profile
    -l, --level N            Expensive Activities detailed profile maximum depth level
    -s, --self               Print top self periods
    -d, --dump               Dump each Expensive Activity raw log to separate file
    -r, --rescan             Do not use cached index and forcibly rescan instrumentation log file
    -h, --help               Print help
```

#### More Info

More details about how to use this tool here - http://afedotov.github.io/ILRT

