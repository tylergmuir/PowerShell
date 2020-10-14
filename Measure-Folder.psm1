function Measure-Folder {
    [CmdletBinding()]
    param(
        [parameter(ValueFromPipeline=$True)]
        [System.IO.DirectoryInfo[]]$Path
    )
    begin {
        Write-Verbose 'Creating runspace pool.'
        $WorkerFlags = @('static','nonpublic','instance')
        $WorkerObj = [powershell]::Create().GetType().GetField('worker', $WorkerFlags)
        $RunspacePool = [runspacefactory]::CreateRunspacePool(1, 10)
        $RunspacePool.Open()
        $Jobs = @()
        $ScriptBlock = {
            param (
                [System.IO.DirectoryInfo]$Path
            )
            ($Path | Get-ChildItem -Recurse -Force | Measure-Object -Property Length -Sum).Sum
        }
        Write-Verbose 'Runspace pool created.'
    }
    process {
        foreach ($Folder in $Path) {
            Write-Verbose "Creating and queuing job for $($Folder.FullName)"
            $Job = [powershell]::Create().AddScript($ScriptBlock).AddArgument($Folder)
            $Job.RunspacePool = $RunspacePool
            $Jobs += New-Object psobject -Property @{
                Pipe = $Job
                Result = $null
                Name = $Folder.Name
                FullName = $Folder.FullName
                StartTime = $null
            }
        }
    }
    end {
        if ($Jobs.Count -lt 500) {
            $SleepCount = 1000
        } elseif ($Jobs.Count -gt 2500) {
            $SleepCount = 5000
        } else {
            $SleepCount = 2 * $Jobs.Count
        }
        Write-Verbose "Setting sleep cylce to $SleepCount milliseconds."
        foreach ($Job in $Jobs) {$Job.Result = $Job.Pipe.BeginInvoke()}
        while ($Jobs.Result.IsCompleted -contains $false) {
            foreach ($Job in $Jobs) {
                if ($Job.Result.IsCompleted -eq $false) {
                    if ($Job.StartTime) {
                        if ((New-TimeSpan -Start $Job.StartTime).TotalMilliseconds -gt 10*$SleepCount) {
                            Write-Verbose "Processing path $($Job.FullName) has taken $([int](New-TimeSpan -Start $Job.StartTime).TotalSeconds) seconds."
                        }
                    } elseif ([bool]$WorkerObj.FieldType.GetProperty('CurrentlyRunningPipeline',$WorkerFlags).GetValue($WorkerObj.GetValue($Job.Pipe))) {
                        $Job.StartTime = Get-Date
                    }
                }
            }

            $CompletedJobCount = ($Jobs | Where-Object {$_.Result.IsCompleted -eq $true} | Measure-Object).Count
            Write-Progress -Activity 'Processing queued jobs' -Status "$CompletedJobCount of $($Jobs.Count) jobs completed" -PercentComplete ($CompletedJobCount/$($Jobs.Count)*100)
            Start-Sleep -Milliseconds $SleepCount
        }

        $Jobs | Where-Object {$_.Pipe.HasErrors -eq $true} | Foreach-Object {
            Write-Error "Failed to measure folder $($_.FullName)"
        }

        $Size = ($Jobs | ForEach-Object {$_.Pipe.EndInvoke($_.Result)} | Measure-Object -Sum).Sum

        Write-Output ('{0:N2} MB' -f ($Size / 1MB))

        $RunspacePool.Close()
    }
}
