This is an Unraid Plugin that when installed will set a system job to run "docker image prune -a" every day at 3am local time.
When removed it will remove the job.
The plugin will allow the user to turn the job on and off, and set the cadence of when this runs.

In the setting there should be a button to run "docker volume prune -f" to remove leftover volumes.
This should NEVER run by default, and this should require conformation.