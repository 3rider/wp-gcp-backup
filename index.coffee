_         = require 'lodash' 
fs        = require 'fs'
path      = require 'path'
moment    = require 'moment'
archiver  = require 'archiver'
mysqlDump = require 'mysqldump'
Promise   = require 'bluebird'
CronJob   = require('cron').CronJob

# GCP
gcs = require('@google-cloud/storage')()
bucket = gcs.bucket 'MY-GCS-BUCKET' # Your bucket name

# Params
timezone      = 'Asia/Hong_Kong' # Cron job timezone
cronInterval  = '0 0 4 * * *' # Run every day at 4a.m.
bakFilename   = "backup-#{moment().format("YYYYMMDDHH")}.zip"

# Config
config =
  out: "#{__dirname}/#{bakFilename}" # Temporary zipped backup path
  wordpress:
    dir: '/var/www/html/wp' # Wordpress root dir
  mysql:
    host: 'localhost'
    user: 'root'
    password: ''
    database: 'wp'
    dest: "#{__dirname}/wp.sql" # Temporary sql dump file path

# Dump Mysql
backupMysql = ->
  return new Promise (rs, rj) ->
    mysqlDump config.mysql, (err) ->
      return rj err if err?
      rs config.mysql.dest

# Backup Wordpress with MySQL
createZip = (sqlPath) ->
  return new Promise (rs, rj) ->
    output  = fs.createWriteStream config.out
    archive = archiver 'zip',
      store: true
      cwd: 'wordpress'
    archive.pipe output

    # Listener
    output.on 'close', ->
      console.log "#{archive.pointer()} total bytes"
      return rs()

    output.on 'error', (err) ->
      return rj err

    # Add SQL Dump
    archive.file sqlPath,
      name: "#{config.mysql.database}.sql"

    # Add Wordpress Directories
    archive.directory config.wordpress.dir, '/wordpress'

    # Finalize Zip
    archive.finalize()

# Push to Google Cloud Storage
pushToGCS = ->
  return new Promise (rs, rj) ->
    file = bucket.file bakFilename
    fs
      .createReadStream config.out
      .pipe file.createWriteStream({ gzip: true })
      .on 'error', (err) ->
        return rj err
      .on 'finish', ->
        console.log 'Pushed to GCS'
        return rs()

# Cron Job
job = new CronJob 
  cronTime: cronInterval
  onTick: ->
    console.log 'Dumping MySQL database...'
    backupMysql()
      .then (sqlPath) ->
        console.log 'Zipping Wordpress directory...'
        return createZip sqlPath
      .then ->
        console.log "Pushing #{bakFilename} to Google cloud storage..."
        return pushToGCS()
      .then ->
        console.log 'Backup success!'
      .catch (err) ->
        console.error err
      .finally ->
        console.log 'Deleting local backup files...'
        try
          fs.unlinkSync config.out
          fs.unlinkSync config.mysql.dest
  start: false
  timezone: timezone

# Start Job
job.start()
console.log 'Monitoring...'