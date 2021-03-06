#!powershell
# -*- coding: utf-8 -*-

# Copyright: (c) 2017, Dag Wieers (@dagwieers) <dag@wieers.com>
# GNU General Public License v3.0+ (see COPYING or https://www.gnu.org/licenses/gpl-3.0.txt)

#Requires -Module Ansible.ModuleUtils.Legacy

$ErrorActionPreference = "Stop"

$params = Parse-Args $args -supports_check_mode $true
$check_mode = Get-AnsibleParam -obj $params -name "_ansible_check_mode" -type "bool" -default $false

$include_volumes = Get-AnsibleParam -obj $params -name "include_volumes" -type "list"
$exclude_volumes = Get-AnsibleParam -obj $params -name "exclude_volumes" -type "list"
$freespace_consolidation = Get-AnsibleParam -obj $params -name "freespace_consolidation" -type "bool" -default $false
$priority = Get-AnsibleParam -obj $params -name "priority" -type "string" -default "low" -validateset "low","normal"
$parallel = Get-AnsibleParam -obj $params -name "parallel" -type "bool" -default $false

$result = @{
    changed = $false
}

$executable = "defrag.exe"

if (-not (Get-Command -Name $executable -ErrorAction SilentlyContinue)) {
    Fail-Json $result "Command '$executable' not found in $env:PATH."
}

$util_def = @'
using System;
using System.ComponentModel;
using System.IO;
using System.Threading;

namespace Ansible.Command {

    public static class NativeUtil {

        public static void GetProcessOutput(StreamReader stdoutStream, StreamReader stderrStream, out string stdout, out string stderr) {
            var sowait = new EventWaitHandle(false, EventResetMode.ManualReset);
            var sewait = new EventWaitHandle(false, EventResetMode.ManualReset);

            string so = null, se = null;

            ThreadPool.QueueUserWorkItem((s)=> {
                so = stdoutStream.ReadToEnd();
                sowait.Set();
            });

            ThreadPool.QueueUserWorkItem((s) => {
                se = stderrStream.ReadToEnd();
                sewait.Set();
            });

            foreach(var wh in new WaitHandle[] { sowait, sewait })
                wh.WaitOne();

            stdout = so;
            stderr = se;
        }
    }
}
'@

Add-Type -TypeDefinition $util_def

$arguments = ""

if ($include_volumes) {
    foreach ($volume in $include_volumes) {
        if ($volume.Length -eq 1) {
            $arguments += " $($volume):"
        } else {
            $arguments += " $volume"
        }
    }
} else {
    $arguments = " /C"
}

if ($exclude_volumes) {
    $arguments += " /E"
    foreach ($volume in $exclude_volumes) {
        if ($volume.Length -eq 1) {
            $arguments += " $($volume):"
        } else {
            $arguments += " $volume"
        }
    }
}

if ($check_mode) {
    $arguments += " /A"
} elseif ($freespace_consolidation) {
    $arguments += " /X"
}

if ($priority -eq "normal") {
    $arguments += " /H"
}

if ($parallel) {
    $arguments += " /M"
}

$arguments += " /V"

$proc = New-Object System.Diagnostics.Process
$psi = $proc.StartInfo
$psi.FileName = $executable
$psi.Arguments = $arguments
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.UseShellExecute = $false

$result.cmd = "$executable$arguments"

$start_datetime = [DateTime]::UtcNow

Try {
    $proc.Start() | Out-Null # will always return $true for non shell-exec cases
} Catch [System.ComponentModel.Win32Exception] {
    # fail nicely for "normal" error conditions
    # FUTURE: this probably won't work on Nano Server
    $excep = $_
    $result.rc = $excep.Exception.NativeErrorCode
    Fail-Json $result $excep.Exception.Message
}

$stdout = $stderr = [string] $null

[Ansible.Command.NativeUtil]::GetProcessOutput($proc.StandardOutput, $proc.StandardError, [ref] $stdout, [ref] $stderr) | Out-Null

$result.stdout = $stdout
$result.stderr = $stderr

$proc.WaitForExit() | Out-Null

$result.rc = $proc.ExitCode

$end_datetime = [DateTime]::UtcNow

$result.start = $start_datetime.ToString("yyyy-MM-dd hh:mm:ss.ffffff")
$result.end = $end_datetime.ToString("yyyy-MM-dd hh:mm:ss.ffffff")
$result.delta = $($end_datetime - $start_datetime).ToString("h\:mm\:ss\.ffffff")

$result.changed = $true

Exit-Json $result
