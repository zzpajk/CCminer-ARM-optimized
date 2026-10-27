#!/usr/bin/env bash
# phone-runner.sh v1.0 - lets Claude queue Verus benchmark jobs for this phone through a private GitHub repo.
#
# The phone polls the jobs repo (git over SSH with a deploy key that can only reach that one repo), runs
# each new job for this phone and commits the output back. A job can ONLY run one of the scripts in
# tools/ of the public fork (github.com/zzpajk/CCminer-ARM-optimized) at a pinned commit, with arguments
# from a fixed character set; nothing from the job file is ever evaluated as shell code.
#
#   bash phone-runner.sh setup NAME   one-time: key, deploy-key check, clone, config, start (NAME = s8, s20, ...)
#   bash phone-runner.sh start|stop|status|log
#
# Jobs repo layout (written by Claude):    jobs/NAME/<id>.job
#   script=bench | sweep | info | runner-update
#   commit=<fork commit, full 40-hex SHA> (not needed for info)
#   arg=<one argument per line>          e.g.  arg=-v   then   arg=baseline x2auto x2percore
#   timeout=<minutes>                    optional, default 240
# Results (written by the phone):         results/NAME/<id>/{status,console.log,report.txt}, results/NAME/heartbeat.txt
set -u
RUNNER_VERSION=1.0
JOBS_REPO="${VERUS_JOBS_REPO:-git@github.com:zzpajk/verus-phone-jobs.git}"
FORK="${VERUS_FORK:-https://github.com/zzpajk/CCminer-ARM-optimized.git}"
CONF="$HOME/.verus-runner.conf"
KEY="$HOME/.ssh/verus_jobs_key"
DIR="$HOME/verus-phone-jobs"
RUNS="$HOME/verus-runs"
SELF="$HOME/phone-runner.sh"
PIDF="$HOME/.verus-runner.pid"
LOGF="$HOME/verus-runner.log"
export GIT_SSH_COMMAND="ssh -i $KEY -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=20"

say() { echo "[$(date '+%F %T')] $*"; }
running() { [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF")" 2>/dev/null; }

push_results() { # message
	( cd "$DIR" || exit 1
	  git add -A "results/$PHONE" >/dev/null 2>&1
	  git diff --cached --quiet && exit 0
	  git -c user.name="$PHONE" -c user.email="$PHONE@phones.invalid" commit -qm "$PHONE: $1" || exit 1
	  for i in 1 2 3 4 5; do
		git pull -q --rebase origin main >/dev/null 2>&1
		git push -q origin HEAD:main >/dev/null 2>&1 && exit 0
		sleep $((i * 5))
	  done; exit 1 ) || say "push failed ($1), will retry with the next push"
}

valid_arg() { case "$1" in *[!A-Za-z0-9\ ._,:=+/-]*) return 1;; esac; return 0; }

fetch_script() { # commit script-name -> path of a private copy
	mkdir -p "$RUNS"
	[ -d "$RUNS/fork.git" ] || git init -q --bare "$RUNS/fork.git"
	git -C "$RUNS/fork.git" fetch -q --depth 1 "$FORK" "$1" 2>/dev/null || git -C "$RUNS/fork.git" fetch -q "$FORK" variants 2>/dev/null
	local out="$RUNS/scripts/$1-$2"; mkdir -p "$RUNS/scripts"
	git -C "$RUNS/fork.git" show "$1:tools/$2" > "$out" 2>/dev/null || { rm -f "$out"; return 1; }
	echo "$out"
}

run_job() { # job-file
	local f=$1 id script="" commit="" tmo=240 args=() line k v rc=0
	id=$(basename "$f" .job)
	local R="$DIR/results/$PHONE/$id"; mkdir -p "$R"
	set -f
	while IFS= read -r line || [ -n "$line" ]; do
		line=${line%$'\r'}; case "$line" in ''|\#*) continue;; esac
		k=${line%%=*}; v=${line#*=}
		case "$k" in
		script) script=$v;; commit) commit=$v;; timeout) tmo=$v;;
		arg) valid_arg "$v" || { echo "failed $(date '+%F %T') bad argument: $v" > "$R/status"; set +f; push_results "job $id rejected"; return; }
		     args+=("$v");;
		*) echo "failed $(date '+%F %T') unknown key: $k" > "$R/status"; set +f; push_results "job $id rejected"; return;;
		esac
	done < "$f"
	set +f
	case "$tmo" in ''|*[!0-9]*) tmo=240;; esac
	case "$script" in bench|sweep|runner-update) case "$commit" in [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;; *)
		echo "failed $(date '+%F %T') bad commit: $commit" > "$R/status"; push_results "job $id rejected"; return;; esac;;
	info) ;; *) echo "failed $(date '+%F %T') unknown script: $script" > "$R/status"; push_results "job $id rejected"; return;; esac
	case "$commit" in *[!0-9a-f]*) echo "failed $(date '+%F %T') bad commit: $commit" > "$R/status"; push_results "job $id rejected"; return;; esac

	# never run on top of a benchmark someone started by hand
	while pgrep -f 'ccminer.*--benchmark' >/dev/null 2>&1; do say "a benchmark is already running, waiting"; sleep 60; done

	echo "running $(date '+%F %T') runner $RUNNER_VERSION" > "$R/status"
	push_results "job $id started"
	say "job $id: $script ${commit:+@$commit} ${args[*]:-}"
	local path="" W=""
	case "$script" in
	info)
		{ echo "runner $RUNNER_VERSION on $PHONE"; date; uname -a; . /etc/os-release 2>/dev/null; echo "os: ${PRETTY_NAME:-?}"
		  echo "clang: $(clang --version 2>/dev/null | head -1)"; echo "uptime: $(uptime)"
		  grep -m1 '^Features' /proc/cpuinfo; awk '/^processor/{p=$3} /^CPU implementer/{i=$4} /^CPU part/{print "  cpu" p ": " i ":" $4}' /proc/cpuinfo
		  for c in /sys/devices/system/cpu/cpu[0-9]*; do echo "  ${c##*/} max=$(cat $c/cpufreq/cpuinfo_max_freq 2>/dev/null) cur=$(cat $c/cpufreq/scaling_cur_freq 2>/dev/null)"; done
		  echo "battery: $(cat /sys/class/power_supply/battery/capacity 2>/dev/null)% $(cat /sys/class/power_supply/battery/status 2>/dev/null) temp=$(cat /sys/class/power_supply/battery/temp 2>/dev/null)"
		  echo "free: $(free -m 2>/dev/null | awk 'NR==2{print $2" MB total, "$7" MB available"}')  disk: $(df -h "$HOME" | awk 'NR==2{print $4" free"}')"
		  pgrep -fa ccminer || echo "no ccminer running"
		} > "$R/console.log" 2>&1; rc=0;;
	runner-update)
		path=$(fetch_script "$commit" phone-runner.sh) && bash -n "$path" && cp "$path" "$SELF" && chmod +x "$SELF" \
			&& echo "updated to $(grep -m1 '^RUNNER_VERSION=' "$SELF")" > "$R/console.log" || { echo "update failed" > "$R/console.log"; rc=1; }
		echo "$([ $rc = 0 ] && echo done || echo failed) $(date '+%F %T') rc=$rc" > "$R/status"; push_results "job $id finished"
		[ $rc = 0 ] && { say "restarting with the new runner"; exec bash "$SELF" loop; }
		return;;
	bench|sweep)
		local sname=verus-ref-bench.sh; [ "$script" = sweep ] && sname=verus-core-sweep.sh
		path=$(fetch_script "$commit" "$sname") || { echo "failed $(date '+%F %T') could not fetch $sname at $commit" > "$R/status"; push_results "job $id failed"; return; }
		W="$RUNS/work-$script-${commit:0:7}"; mkdir -p "$W"
		# live progress: copy the console log into the repo every 5 minutes while the job runs
		( VERUS_WORK="$W" VERUS_SWEEP_DIR="$W" timeout $((tmo * 60)) bash "$path" "${args[@]}" < /dev/null > "$R/console.log" 2>&1; echo $? > "$W/.rc" ) &
		local jp=$! n=0
		while kill -0 $jp 2>/dev/null; do sleep 10; n=$((n + 1)); [ $((n % 30)) = 0 ] && push_results "job $id progress"; done
		rc=$(cat "$W/.rc" 2>/dev/null || echo 1); rm -f "$W/.rc"
		[ "$script" = bench ] && [ -f "$W/report.txt" ] && [ "$W/report.txt" -nt "$R/status" ] && cp "$W/report.txt" "$R/report.txt"
		[ "$script" = sweep ] && sed -n '/= RESULT/,$p' "$R/console.log" > "$R/report.txt";;
	esac
	echo "$([ "$rc" = 0 ] && echo done || echo failed) $(date '+%F %T') rc=$rc" > "$R/status"
	push_results "job $id finished rc=$rc"
	say "job $id finished rc=$rc"
}

heartbeat() {
	mkdir -p "$DIR/results/$PHONE"
	{ echo "alive $(date '+%F %T') runner $RUNNER_VERSION"; echo "uptime: $(uptime)"
	  echo "battery: $(cat /sys/class/power_supply/battery/capacity 2>/dev/null)% $(cat /sys/class/power_supply/battery/status 2>/dev/null)"
	} > "$DIR/results/$PHONE/heartbeat.txt"
	push_results "heartbeat"
}

loop() {
	. "$CONF" || { echo "no $CONF, run setup first"; exit 1; }
	echo $$ > "$PIDF"
	git -C "$DIR" config user.name "$PHONE"; git -C "$DIR" config user.email "$PHONE@phones.invalid"
	say "runner $RUNNER_VERSION for $PHONE started (pid $$)"
	local last_hb=0 now
	while :; do
		( cd "$DIR" && git pull -q --rebase origin main ) >/dev/null 2>&1 || say "pull failed (network?)"
		for f in $(ls "$DIR/jobs/$PHONE"/*.job 2>/dev/null | sort); do
			[ -f "$DIR/results/$PHONE/$(basename "$f" .job)/status" ] && continue
			run_job "$f"; last_hb=$(date +%s)
		done
		now=$(date +%s)
		[ $((now - last_hb)) -ge 1800 ] && { heartbeat; last_hb=$now; }
		sleep 60
	done
}

case "${1:-}" in
setup)
	PHONE=${2:-}; case "$PHONE" in ''|*[!a-z0-9-]*) echo "usage: bash phone-runner.sh setup NAME   (NAME: lowercase letters/digits, e.g. s8)"; exit 1;; esac
	for c in git ssh ssh-keygen; do command -v $c >/dev/null || { echo "missing $c (sudo apt-get install git openssh-client)"; exit 1; }; done
	[ "$(readlink -f "$0")" != "$(readlink -f "$SELF")" ] && cp "$0" "$SELF" && chmod +x "$SELF"
	mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
	[ -f "$KEY" ] || ssh-keygen -q -t ed25519 -N "" -C "verus-jobs-$PHONE" -f "$KEY"
	echo; echo "Add this key to github.com/zzpajk/verus-phone-jobs -> Settings -> Deploy keys -> Add deploy key"
	echo "(title: $PHONE, tick 'Allow write access'):"; echo; cat "$KEY.pub"; echo
	until git ls-remote "$JOBS_REPO" >/dev/null 2>&1; do read -r -p "Press Enter once the key is added (Ctrl-C to stop)... " _ </dev/tty; done
	echo "Key works."
	[ -d "$DIR/.git" ] || git clone -q "$JOBS_REPO" "$DIR" || { echo "clone failed"; exit 1; }
	echo "PHONE=$PHONE" > "$CONF"
	running && kill "$(cat "$PIDF")" 2>/dev/null
	nohup setsid bash "$SELF" loop >> "$LOGF" 2>&1 < /dev/null &
	sleep 2; running && echo "Runner started for $PHONE (log: $LOGF). It survives logging out of SSH; after a phone reboot run: bash $SELF start" \
		|| { echo "Runner did not start, see $LOGF"; exit 1; };;
start) running && { echo "already running (pid $(cat "$PIDF"))"; exit 0; }
	nohup setsid bash "$SELF" loop >> "$LOGF" 2>&1 < /dev/null & sleep 2; running && echo "started" || echo "failed, see $LOGF";;
stop) running && kill "$(cat "$PIDF")" && pkill -f 'verus-ref-bench.sh|verus-core-sweep.sh' ; rm -f "$PIDF"; echo "stopped";;
status) running && echo "running (pid $(cat "$PIDF"))" || echo "not running"; tail -5 "$LOGF" 2>/dev/null;;
log) tail -40 "$LOGF";;
loop) loop;;
*) sed -n '2,20p' "$0";;
esac
