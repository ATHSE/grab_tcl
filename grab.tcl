#!/usr/bin/tclsh
#---------------------------------
# GRAB - automated link sucker (c) 2006 - Revision 41
#
# This script will read/parse grab.txt for referrer and download links.
#
# Referrer URLS in grab.txt are preceded by exclamation marks (!).
# Download URLS in grab.txt can have standard server arguments appended.
#
# To create a break point in grab.txt, add a simple "EOF" on its own line.
#
# This script doesn't support encryption methods in this iteration, so
# all URLs must specify without (http://...) or will not be processed.
#
# This script will take a single download URL as an argument, but this
# was intended as more of a batch downloader, with an accompanying program
# or script generating the grab.txt links.
#
# This code should be easy to integrate into a larger script without using
# a namespace, as the only globals used are distinctly web-related:
#  webinit, webdata, webbuffer, weburlcache

# show verbose messages in console
#
set webinit(debug) 1

# download settings
#
set webinit(timeout) 45 ;# global timeout in seconds
set webinit(adaptive) 1 ;# adaptive timeout for slow connections

set webinit(retrycount) 2
set webinit(keepbroken) 1 ;# save partial downloads

set webinit(renameonexist) 0
set webinit(skipifexist) 1
set webinit(appendifexist) 1
set webinit(saveinsubdir) 1

# declare web-client features
#
set webinit(chunking) 1

# override internal browser string
#
#set webinit(agent) "Mosaic/2.0 (compatible, Windows 98)  \[en\]"
#set webinit(agent) "Mozilla/4.0 (compatible, UNIX, U)  \[en\]"
#set webinit(agent) "Mozilla/5.0 (compatible, MSIE, 5.0.1229, Windows 2000) \[en\]"

# override internal web protocol, supports 1.0 and 1.1 (default)
#
set webinit(proto) "HTTP/1.1"

# define web-proxy
#
set webinit(proxy) ""

################################################################# begin code.

# background error catch-all
proc bgerror {msg} {
	puts "ERROR: $msg"
	foreach fid [file channels file*] {catch {close $fid} msg}
	exit
}

proc webputs {port string} {
	global webinit
	if {$webinit(debug)} {puts "*request* $string"}
	puts $port $string
}

proc webopen {method url {page "/"} {args ""} {referrer ""} {auth ""}} {
	global webinit webdata webbuffer weburlcache
	set webdata $args
	set pord 80
	set url [split $url ":"]
	if {[llength $url] > 1} {
		set host [lindex $url 0] ; set pord [lindex $url 1]
	} else {
		set host $url ; set pord 80
	}
	set webbuffer(istate) 0
	set webbuffer(iware) $method
	set webbuffer(size) 0
	set webbuffer(buffer) 0
	set webbuffer(page) ""
	set webbuffer(expire) [clock seconds]
	set webbuffer(chunk) 8192
	set webbuffer(referrer) $referrer
	if ![string equal "" $auth] {set webbuffer(auth) [enc64 $auth]} else {set webbuffer(auth) ""}
	if ![string equal "" $referrer] {set webbuffer(referrer) $referrer}
	set webbuffer(url) $host
	if [info exists weburlcache($host)] {puts "DNS: $host using cached address" ; set host $weburlcache($host)} else {puts "DNS: $host isn't cached"}
	if [string equal "" $webinit(proxy)] {
		append webbuffer(page) $page
	## direct
		if {$webinit(debug)} {puts "web: connecting to $host $pord ..."}
		set rc [catch {socket -async $host $pord} webbuffer(iport)]
	} else {
		append webbuffer(page) "http://$host"
		if {[string index $page 0] != "/"} {append webbuffer(page) "/"}
		append webbuffer(page) $page
	## pick a proxy
		set num [expr round([expr rand() * [llength $webinit(proxy)]])] ; if {$num != 0} {incr num -1}
		foreach {host pord} [split [lindex $webinit(proxy) $num] ":"] {}
		if {$webinit(debug)} {puts "web: connecting to $host $pord ..."}
		set rc [catch {socket -async $host $pord} webbuffer(iport)]
	}
	if {$pord != 80} {append webbuffer(url) ":$pord"}
	if {$rc != 1} {
		if {$webinit(debug)} {puts "web: opening connection $webbuffer(iport)"}
		fconfigure $webbuffer(iport) -blocking 0 -buffering line -translation {auto crlf}
		fileevent $webbuffer(iport) writable webalive
		set webbuffer(iwait) [after [expr $webinit(timeout) * 1000] {set webbuffer(iware) "timeout" ; set webbuffer(istate) 1}]
		if {$webinit(debug)} {puts "web: spawned $webbuffer(iwait)"}
		vwait webbuffer(istate)
		if {$webinit(debug)} {puts "web: wait done >> $webbuffer(iware) ([string length $webdata])"}
		webclose
		if {$webinit(debug)} {puts "web: completed ([expr [clock seconds] - $webbuffer(expire)]s)"}
	} else {
		webclose
		if {$webinit(debug)} {puts "web: $webbuffer(iport) error ([expr [clock seconds] - $webbuffer(expire)]s)"}
	}
}

proc webalive {} {
	global webbuffer weburlcache
	if {[eof $webbuffer(iport)] || ![string equal "" [fconfigure $webbuffer(iport) -error]]} {
		if {$webinit(debug)} {puts "web: [fconfigure $webbuffer(iport) -error] error ([expr [clock seconds] - $webbuffer(expire)]s)"}
	} else {
		set url $webbuffer(url)
		if ![string match "*.*.*.*" $url] {
			set weburlcache($url) [lindex [fconfigure $webbuffer(iport) -peername] 0]
		}
		fileevent $webbuffer(iport) writable {}
		webget
	}
}

proc webclose {} {
	global webinit webbuffer
	fileevent $webbuffer(iport) writable {}
	fileevent $webbuffer(iport) readable {}
	set webbuffer(resume) 0
	catch {after cancel [set webbuffer(iwait)]}
	if {$webinit(debug)} {puts "web: closing connection"}
	catch {close $webbuffer(iport)} msg
	if [info exists webbuffer(istate)] {unset webbuffer(istate)}
}

proc webget {} {
	global webinit webdata webbuffer
	if {[lsearch [file channels] $webbuffer(iport)] == -1 || [eof $webbuffer(iport)]} {
		set webbuffer(iware) "closed"
		set webbuffer(istate) 1
	}
	switch -- $webbuffer(iware) {
		POST -
		GET {
			if {$webinit(debug)} {puts "web: sending request header"}
			if ![info exists webinit(proto)] {set webinit(proto) "HTTP/1.1"}
			webputs $webbuffer(iport) "$webbuffer(iware) $webbuffer(page) $webinit(proto)"
			if ![info exists webinit(agent)] {set webinit(agent) "web.tcl/1.0 (compatible, UNIX; U)  \[en\]"}
			webputs $webbuffer(iport) "User-Agent: $webinit(agent)"
			webputs $webbuffer(iport) "Host: $webbuffer(url)"
			webputs $webbuffer(iport) "Accept: text/html, */*"
			webputs $webbuffer(iport) "Accept-Language: en"
			webputs $webbuffer(iport) "Accept-Encoding: identity, *;q=0"
			webputs $webbuffer(iport) "Accept-Charset: windows-1252;q=1.0, iso-8859-1;q=0.6, *;q=0.1"
			if ![string equal "" $webbuffer(referrer)] {webputs $webbuffer(iport) "referrer: $webbuffer(referrer)"}
			if ![string equal "" $webinit(proxy)] {
				webputs $webbuffer(iport) "Cache-Control: no-cache"
			}
			# declare this request offset
			if ![info exists webbuffer(resume)] {set webbuffer(resume) 0} ;# init value
			if {$webbuffer(resume) != 0} {
				webputs $webbuffer(iport) "Range: bytes=$webbuffer(resume)-"
			}
			if {$webinit(chunking) == 1} {
				webputs $webbuffer(iport) "Connection: Keep-Alive, TE"
				webputs $webbuffer(iport) "TE: chunked, identity"
			} else {
				webputs $webbuffer(iport) "Connection: Keep-Alive, TE"
				webputs $webbuffer(iport) "TE:"
			}
			set args [string length $webdata]
			if {$args != 0} {
				webputs $webbuffer(iport) "Content-type: application/x-www-form-urlencoded"
				webputs $webbuffer(iport) "Content-length: $args"
			}
			if ![string equal "" $webbuffer(auth)] {webputs $webbuffer(iport) "Authorization: Basic $webbuffer(auth)"}
			webputs $webbuffer(iport) ""
			flush $webbuffer(iport)

			set webbuffer(rtype) "header"
			set webbuffer(iware) "read_text"
			fileevent $webbuffer(iport) readable webget
			set webinit(chunking) 0
		}
		body_ok {
			webputs $webbuffer(iport) $webdata
			flush $webbuffer(iport)
			set webbuffer(iware) "read_text"
			set webbuffer(rtype) "reply"
			set webdata ""
			fileevent $webbuffer(iport) writable {}
			fileevent $webbuffer(iport) readable webget
		}
		read_text {
			set bufline ""
			if [catch {gets $webbuffer(iport) bufline} number] {set webbuffer(iware) "closed" ; set webbuffer(istate) 1 ; return}
			if [fblocked $webbuffer(iport)] {return}
			switch $webbuffer(rtype) {
				reply {
					if {$webinit(debug)} {puts "*$webbuffer(rtype)* $bufline"}
					switch -exact [string tolower [lindex $bufline 0]] {
						content-length: {
							set size [lindex $bufline 1]
							set webbuffer(size) $size
							set webbuffer(chunk) $size
							set webinit(chunking) -3
							puts "web: expecting document --> $size"
						}
						accept-ranges: -
						content-range: {
							if {[string equal -nocase "bytes" [lindex $bufline 1]]} {set webbuffer(resume) 0}
						}
						connection: { 
							if [string equal [lindex $bufline 1] "close"] {incr webinit(chunking)}
						}
						transfer-encoding: {
							if [string equal [lindex $bufline 1] "chunked"] {incr webinit(chunking)}
						}
						{} {
							if {$webinit(chunking) > 0} {
								set webbuffer(rtype) "chunksize"
							} else {
								set webbuffer(iware) "read_bin"
								set webbuffer(rtype) "done"
							}
							if ![string match {[12]0[06]} $webbuffer(code)] {
								set webbuffer(iware) "bad code" ; set webbuffer(istate) 1 ; return
							}
							if {$webbuffer(code) == 302} {set webbuffer(iware) "redirect ignored" ; set webbuffer(istate) 1 ; return}
							fconfigure $webbuffer(iport) -translation binary
						}
					}
				}
				header {
					if [string equal "" $bufline] {return}
					foreach {vers rc} $bufline {break}
					fileevent $webbuffer(iport) readable {}
					if ![string match "HTTP/1.?" $vers] {
						if {$webinit(debug)} {puts "web: bad or unknown response - $bufline"}
						set rc 500
					} else {
						if {$webinit(debug)} {puts "*server* $bufline"}
					}
					switch -- $rc { 
						100 -
						206 -
						200 {
							set webbuffer(iware) "body_ok"
							fileevent $webbuffer(iport) readable {}
							fileevent $webbuffer(iport) writable webget
						}
						301 -
						302 -
						416 -
						404 {
							set webbuffer(iware) "null"
							set webbuffer(istate) 1
						}
						default {
							set webbuffer(iware) "server error"
							set webbuffer(istate) 1
						}
					}
					set webbuffer(code) $rc
				}
				chunksize {
					if [regexp {[A-Fa-f0-9]+} $bufline chunkline] {
						##if ![string equal $bufline $chunkline] {puts "chunking mismatch" ; return}
						set chunk [expr 1 * (0x$chunkline + 1)]
						fconfigure $webbuffer(iport) -translation binary
						set webbuffer(iware) "read_bin"
						set webbuffer(chunk) $chunk
					} else {
						return
						# web servers often lie
						# set chunk -1 
					}
					if {$webinit(debug)} {puts "web: expecting chunk --> $chunk"}
					if {$chunk == 0} {set webbuffer(iware) "complete" ; set webbuffer(istate) 1 ; return}
				}
			}
		}
		read_bin {
			set bufline "" ; set chunk $webbuffer(chunk)
			set bufline [read $webbuffer(iport) $chunk]
			append webdata $bufline
			if {[string length $webdata] >= 262144} {grabdump}
			set rs [string length $bufline]
			incr webbuffer(buffer) $rs
			if {$rs < $chunk} {
				incr chunk [expr $rs * -1]
				if {$webinit(debug)} {puts "*$webbuffer(rtype)* partial chunk ($rs) received: $webbuffer(buffer)"}
				set webbuffer(chunk) $chunk
				if {$webinit(adaptive) == 1} {
					catch {after cancel [set webbuffer(iwait)]}
					set webbuffer(iwait) [after [expr $webinit(timeout) * 1000] {set webbuffer(istate) 1}]
				}
			} else {
				if {$webinit(debug)} {puts "*$webbuffer(rtype)* complete chunk ($rs) received: $webbuffer(buffer)"}
				if {$webinit(chunking) > 0 && $webbuffer(buffer) < $webbuffer(size)} {
					fconfigure $webbuffer(iport) -translation {auto}
					set webbuffer(iware) "read_text"
					set webbuffer(rtype) "chunksize"
				} else {
					puts "*$webbuffer(rtype)* end of data stream"
					set webbuffer(iware) "complete"
					set webbuffer(istate) 1
					return
				}
			}
		}
	}
}

proc grabdump {fileid} { 
	global webdata webbuffer
	set msg ""
	if ![string equal "" $webdata] {catch {puts -nonewline $fileid $webdata} msg}
	if {![string equal "" $msg] && $msg != 0} {
		puts "GRAB error, unable to write file!"
		close $fileid
		set webbuffer(istate) 1
		return
	}
	if ![string equal "" $webdata] {incr webbuffer(tsize) [string length $webdata] ; set webdata ""}
}

proc grabmain {} {
	global argv webbuffer webinit
	set webbuffer(reefer) ""
	set webbuffer(tminus) 0
	set webbuffer(tplus) 0
	set webbuffer(tsize) 0 
	set url ""
	set page "/"
	if {[string match "#*" $argv]} {return}
	if {[string match "!*" $argv]} {set webbuffer(reefer) [string range $argv 1 end] ; return}
	regexp -all {([hH][tT][tT][pP][sS]?://)([^/]+)(/.*)} $argv all prot url page

	if [string equal "" $url] {
		puts "GRAB error, unable to determine host from URL!" ; return
	}
	set lpage $url
	if [string equal "" [file tail $page]] {
		append lpage "/index.htm"
	} else {
		append lpage / [string map {\? {} / {} \* {} \" {} : {} ; {}} $page]
	}
	if [file exists $lpage] {
		set fsize [file size $lpage]
		if {$webinit(skipifexist) == 1 && $fsize > 100} {
			puts "SKIPPING FILE: $lpage"
			return
		} elseif {$webinit(renameonexist) == 1} {
			set pos [string last . $lpage]
			set basen [string range $lpage 0 $pos]
			set extn [string range $lpage $pos end]
			for {set xox 1} {$xox <= 10000} {incr xox} {
				if [file exists $lpage] {
					set lpage $basen ; append lpage $xox $extn
				} else {
					break
				}
			}
		}
	} else {
		set fsize 0
	}
	if {$webinit(saveinsubdir) == 1} {
		if ![file isdirectory $url] {file mkdir $url}
	}
	if {$webinit(appendifexist) == 1 && $fsize > 100} {
		catch {open $lpage a+} fid
		if ![string match "file*" $fid] {
			puts "WRITE ERROR: $lpage" ; return
		}
		set webbuffer(resume) $fsize
	} else {
		catch {open $lpage w} fid
		if ![string match "file*" $fid] {
			puts "WRITE ERROR: $lpage" ; return
		}
		set webbuffer(resume) 0
	}
	puts $webbuffer(resume)
	fconfigure $fid -translation binary
	webopen GET $url $page {} $webbuffer(reefer)
	switch -- $webbuffer(iware) {
		complete {grabdump $fid ; puts "FILE SAVED!"}
		read_bin -
		closed {grabdump $fid}
		{server error} {puts "BAD FILE!"}
		default {}
	}
	if {$webbuffer(buffer) < $webbuffer(size) && ![string match {null} $webbuffer(iware)] && ![string match {server error} $webbuffer(iware)]} {
		for {set xox 1} {$xox <= $webinit(retrycount)} {incr xox} {
			set fsize [file size $lpage]
			after 6000
			if {$webbuffer(buffer) < $webbuffer(size) && ![string match {null} $webbuffer(iware)] && ![string match {server error} $webbuffer(iware)]} {
				puts "GRAB incomplete -> retrying"
				set webbuffer(resume) $fsize
				webopen GET $url $page {} $webbuffer(reefer)
				grabdump
			} else {
				break
			}
		}
	}
	close $fid
	puts "----------------------------------------"
	if [string equal "null" $webbuffer(iware)] {
		puts "GRAB error, file not found or local file exists"
	} elseif {[string equal "complete" $webbuffer(iware)] || [string equal "closed" $webbuffer(iware)]} {
		incr webbuffer(tminus) ; incr webbuffer(tplus) [file size $lpage]
		set ts [expr [clock seconds] - $webbuffer(expire)]
		if {$ts > 0} {set tsize "[expr ($tsize / $ts) / 1024]KB/s"} else {set tsize "FAST"}
		puts "GRAB success, saved as $lpage (avg speed: $tsize)"
	} else {
		if {$webinit(keepbroken) != 1} {
			puts "GRAB error, deleted file $lpage"
			catch {file delete -force $lpage}
		} else {
			incr webbuffer(tminus) ; incr webbuffer(tplus) [file size $lpage]
			puts "GRAB error, truncated file $lpage"
		}
	}
}

# if commandline argument is not blank, grab the argument url, otherwise look for grab.txt
proc grabloop {} {
	global argv webbuffer
	if {[string equal "" $argv] && [file exists "grab.txt"]} {
		catch {open "grab.txt" r} oof
		if ![string match "file*" $oof] {
			puts "GRAB error, unreadable grab.txt"
			exit
		}
		set args [read $oof [file size "grab.txt"]]
		close $oof
		foreach argv [split $args \n] {
			if [string equal "EOF" $argv] {exit} ;# early abort code
			if ![string equal "" [string trim $argv]] {grabmain}
			set argv ""
		}
	} else {
		grabmain
	}
	puts "Queue completed: $webbuffer(tminus) files in [expr $webbuffer(tplus) / 1024]KB saved successfully"
}

grabloop

#---------------------------------
# MIT License:
#
# Permission is hereby granted, free of charge, to any person obtaining a copy 
# of this software and associated documentation files (the “Software”), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# #
# THE SOFTWARE IS PROVIDED “AS IS”, WITHOUT WARRANTY OF ANY KIND, EXPRESS OR 
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
#
#---------------------------------
