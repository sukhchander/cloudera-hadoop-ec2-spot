#!/bin/bash -x
export %ENV%

REPO="cdh2"
HADOOP="hadoop-0.20"

SELF_HOST=`wget -q -O - http://169.254.169.254/latest/meta-data/public-hostname`
for role in $(echo "$ROLES" | tr "," "\n"); do
  case $role in
  nn)
    NN_HOST=$SELF_HOST
    ;;
  jt)
    JT_HOST=$SELF_HOST
    ;;
  esac
done

function update_repo() {
  cat > /etc/apt/sources.list.d/cloudera.list <<EOF
deb http://archive.cloudera.com/debian intrepid-$REPO contrib
deb-src http://archive.cloudera.com/debian intrepid-$REPO contrib
EOF
}

function install_packages() {
  apt-get update
  apt-get -y install $@
}

function install_user_packages() {
  if [ ! -z "$USER_PACKAGES" ]; then
    install_packages $USER_PACKAGES
  fi
}

function install_hadoop() {
  apt-get update
  apt-get -y install $HADOOP
  cp -r /etc/$HADOOP/conf.empty /etc/$HADOOP/conf.dist
  update-alternatives --install /etc/$HADOOP/conf $HADOOP-conf /etc/$HADOOP/conf.dist 90
  apt-get -y install pig${PIG_VERSION:+-${PIG_VERSION}}
  apt-get -y install hive${HIVE_VERSION:+-${HIVE_VERSION}}
  apt-get -y install policykit # http://www.bergek.com/2008/11/24/ubuntu-810-libpolkit-error/
}

function prep_disk() {
  mount=$1
  device=$2
  automount=${3:-false}

  echo "warning: ERASING CONTENTS OF $device"
  mkfs.xfs -f $device
  if [ ! -e $mount ]; then
    mkdir $mount
  fi
  mount -o defaults,noatime $device $mount
  if $automount ; then
    echo "$device $mount xfs defaults,noatime 0 0" >> /etc/fstab
  fi
}

function wait_for_mount {
  mount=$1
  device=$2

  mkdir $mount

  i=1
  echo "Attempting to mount $device"
  while true ; do
    sleep 10
    echo -n "$i "
    i=$[$i+1]
    mount -o defaults,noatime $device $mount || continue
    echo " Mounted."
    break;
  done
}

function make_hadoop_hdfs_dirs {
  AS_HADOOP="su -s /bin/bash - hadoop -c"
  hdfs_dirs=$(echo $@| tr "," "\n")
  for dir in $hdfs_dirs
  do
    echo "$AS_HADOOP mkdir -p $dir"
    $AS_HADOOP "mkdir -p $dir"
    #chown hadoop:hadoop $dir
  done
}

function make_hadoop_dirs {
  for mount in "$@"; do
    if [ ! -e $mount/hadoop ]; then
      mkdir -p $mount/hadoop
      chown hadoop:hadoop $mount/hadoop
    fi
  done
}

function configure_hadoop() {

  install_packages xfsprogs # needed for XFS

  INSTANCE_TYPE=`wget -q -O - http://169.254.169.254/latest/meta-data/instance-type`

  if [ -n "$EBS_MAPPINGS" ]; then
    # EBS_MAPPINGS is like "/ebs1,/dev/sdj;/ebs2,/dev/sdk"
    DFS_NAME_DIR=''
    FS_CHECKPOINT_DIR=''
    DFS_DATA_DIR=''
    for mapping in $(echo "$EBS_MAPPINGS" | tr ";" "\n"); do
      # Split on the comma (see "Parameter Expansion" in the bash man page)
      mount=${mapping%,*}
      device=${mapping#*,}
      wait_for_mount $mount $device
      DFS_NAME_DIR=${DFS_NAME_DIR},"$mount/hadoop/hdfs/name"
      FS_CHECKPOINT_DIR=${FS_CHECKPOINT_DIR},"$mount/hadoop/hdfs/secondary"
      DFS_DATA_DIR=${DFS_DATA_DIR},"$mount/hadoop/hdfs/data"
      FIRST_MOUNT=${FIRST_MOUNT-$mount}
      make_hadoop_dirs $mount
    done
    # Remove leading commas
    DFS_NAME_DIR=${DFS_NAME_DIR#?}
    FS_CHECKPOINT_DIR=${FS_CHECKPOINT_DIR#?}
    DFS_DATA_DIR=${DFS_DATA_DIR#?}

    DFS_REPLICATION=3 # EBS is internally replicated, but we also use HDFS replication for safety
  else
    case $INSTANCE_TYPE in
    m1.xlarge|c1.xlarge)
      DFS_NAME_DIR=/mnt/hadoop/hdfs/name,/mnt2/hadoop/hdfs/name
      FS_CHECKPOINT_DIR=/mnt/hadoop/hdfs/secondary,/mnt2/hadoop/hdfs/secondary
      DFS_DATA_DIR=/mnt/hadoop/hdfs/data,/mnt2/hadoop/hdfs/data,/mnt3/hadoop/hdfs/data,/mnt4/hadoop/hdfs/data
      ;;
    m1.large)
      DFS_NAME_DIR=/mnt/hadoop/hdfs/name,/mnt2/hadoop/hdfs/name
      FS_CHECKPOINT_DIR=/mnt/hadoop/hdfs/secondary,/mnt2/hadoop/hdfs/secondary
      DFS_DATA_DIR=/mnt/hadoop/hdfs/data,/mnt2/hadoop/hdfs/data
      ;;
    *)
      # "m1.small" or "c1.medium"
      DFS_NAME_DIR=/mnt/hadoop/hdfs/name
      FS_CHECKPOINT_DIR=/mnt/hadoop/hdfs/secondary
      DFS_DATA_DIR=/mnt/hadoop/hdfs/data
      ;;
    esac
    FIRST_MOUNT=/mnt
    DFS_REPLICATION=3
  fi

  case $INSTANCE_TYPE in
  m1.xlarge|c1.xlarge)
    prep_disk /mnt2 /dev/sdc true &
    disk2_pid=$!
    prep_disk /mnt3 /dev/sdd true &
    disk3_pid=$!
    prep_disk /mnt4 /dev/sde true &
    disk4_pid=$!
    wait $disk2_pid $disk3_pid $disk4_pid
    MAPRED_LOCAL_DIR=/mnt/hadoop/mapred/local,/mnt2/hadoop/mapred/local,/mnt3/hadoop/mapred/local,/mnt4/hadoop/mapred/local
    MAX_MAP_TASKS=5
    MAX_REDUCE_TASKS=5
    CHILD_OPTS=-Xmx512m
    CHILD_ULIMIT=1048576
    ;;
  m1.large)
    prep_disk /mnt2 /dev/sdc true
    MAPRED_LOCAL_DIR=/mnt/hadoop/mapred/local,/mnt2/hadoop/mapred/local
    MAX_MAP_TASKS=4
    MAX_REDUCE_TASKS=2
    CHILD_OPTS=-Xmx1024m
    CHILD_ULIMIT=2097152
    ;;
  c1.medium)
    MAPRED_LOCAL_DIR=/mnt/hadoop/mapred/local
    MAX_MAP_TASKS=4
    MAX_REDUCE_TASKS=2
    CHILD_OPTS=-Xmx550m
    CHILD_ULIMIT=1126400
    ;;
  *)
    # "m1.small"
    MAPRED_LOCAL_DIR=/mnt/hadoop/mapred/local
    MAX_MAP_TASKS=2
    MAX_REDUCE_TASKS=1
    CHILD_OPTS=-Xmx550m
    CHILD_ULIMIT=1126400
    ;;
  esac

  make_hadoop_dirs `ls -d /mnt*`

  #make_hadoop_hdfs_dirs $DFS_NAME_DIR
  #make_hadoop_hdfs_dirs $FS_CHECKPOINT_DIR
  #make_hadoop_hdfs_dirs $DFS_DATA_DIR
  #make_hadoop_hdfs_dirs $MAPRED_LOCAL_DIR

  # Create tmp directory
  mkdir /mnt/tmp
  chmod a+rwxt /mnt/tmp

  cat > /etc/$HADOOP/conf.dist/hadoop-site.xml <<EOF
<?xml version="1.0"?>
<?xml-stylesheet type="text/xsl" href="configuration.xsl"?>
<configuration>
<property>
  <name>dfs.block.size</name>
  <value>134217728</value>
  <final>true</final>
</property>
<property>
  <name>dfs.data.dir</name>
  <value>$DFS_DATA_DIR</value>
  <final>true</final>
</property>
<property>
  <name>dfs.datanode.du.reserved</name>
  <value>1073741824</value>
  <final>true</final>
</property>
<property>
  <name>dfs.datanode.handler.count</name>
  <value>3</value>
  <final>true</final>
</property>
<!--property>
  <name>dfs.hosts</name>
  <value>/etc/$HADOOP/conf.dist/dfs.hosts</value>
  <final>true</final>
</property-->
<!--property>
  <name>dfs.hosts.exclude</name>
  <value>/etc/$HADOOP/conf.dist/dfs.hosts.exclude</value>
  <final>true</final>
</property-->
<property>
  <name>dfs.name.dir</name>
  <value>$DFS_NAME_DIR</value>
  <final>true</final>
</property>
<property>
  <name>dfs.namenode.handler.count</name>
  <value>5</value>
  <final>true</final>
</property>
<property>
  <name>dfs.permissions</name>
  <value>true</value>
  <final>true</final>
</property>
<property>
  <name>dfs.replication</name>
  <value>$DFS_REPLICATION</value>
</property>
<property>
  <name>fs.checkpoint.dir</name>
  <value>$FS_CHECKPOINT_DIR</value>
  <final>true</final>
</property>
<property>
  <name>fs.default.name</name>
  <value>hdfs://$NN_HOST:8020/</value>
</property>
<property>
  <name>fs.trash.interval</name>
  <value>1440</value>
  <final>true</final>
</property>
<property>
  <name>hadoop.tmp.dir</name>
  <value>/mnt/tmp/hadoop-\${user.name}</value>
  <final>true</final>
</property>
<property>
  <name>io.file.buffer.size</name>
  <value>65536</value>
</property>
<property>
  <name>mapred.child.java.opts</name>
  <value>$CHILD_OPTS</value>
</property>
<property>
  <name>mapred.child.ulimit</name>
  <value>$CHILD_ULIMIT</value>
  <final>true</final>
</property>
<property>
  <name>mapred.job.tracker</name>
  <value>$JT_HOST:8021</value>
</property>
<property>
  <name>mapred.job.tracker.handler.count</name>
  <value>5</value>
  <final>true</final>
</property>
<property>
  <name>mapred.local.dir</name>
  <value>$MAPRED_LOCAL_DIR</value>
  <final>true</final>
</property>
<property>
  <name>mapred.map.tasks.speculative.execution</name>
  <value>true</value>
</property>
<property>
  <name>mapred.reduce.parallel.copies</name>
  <value>10</value>
</property>
<property>
  <name>mapred.reduce.tasks</name>
  <value>10</value>
</property>
<property>
  <name>mapred.reduce.tasks.speculative.execution</name>
  <value>false</value>
</property>
<property>
  <name>mapred.submit.replication</name>
  <value>10</value>
</property>
<property>
  <name>mapred.system.dir</name>
  <value>/hadoop/system/mapred</value>
</property>
<property>
  <name>mapred.tasktracker.map.tasks.maximum</name>
  <value>$MAX_MAP_TASKS</value>
  <final>true</final>
</property>
<property>
  <name>mapred.tasktracker.reduce.tasks.maximum</name>
  <value>$MAX_REDUCE_TASKS</value>
  <final>true</final>
</property>
<property>
  <name>tasktracker.http.threads</name>
  <value>46</value>
  <final>true</final>
</property>
<property>
  <name>mapred.jobtracker.taskScheduler</name>
  <value>org.apache.hadoop.mapred.FairScheduler</value>
</property>
<property>
  <name>mapred.fairscheduler.allocation.file</name>
  <value>/etc/$HADOOP/conf.dist/fairscheduler.xml</value>
</property>
<property>
  <name>mapred.compress.map.output</name>
  <value>true</value>
</property>
<property>
  <name>mapred.output.compression.type</name>
  <value>BLOCK</value>
</property>
<property>
  <name>hadoop.rpc.socket.factory.class.default</name>
  <value>org.apache.hadoop.net.StandardSocketFactory</value>
  <final>true</final>
</property>
<property>
  <name>hadoop.rpc.socket.factory.class.ClientProtocol</name>
  <value></value>
  <final>true</final>
</property>
<property>
  <name>hadoop.rpc.socket.factory.class.JobSubmissionProtocol</name>
  <value></value>
  <final>true</final>
</property>
<property>
  <name>io.compression.codecs</name>
  <value>org.apache.hadoop.io.compress.DefaultCodec,org.apache.hadoop.io.compress.GzipCodec</value>
</property>
<property>
  <name>fs.s3.awsAccessKeyId</name>
  <value>$AWS_ACCESS_KEY_ID</value>
</property>
<property>
  <name>fs.s3.awsSecretAccessKey</name>
  <value>$AWS_SECRET_ACCESS_KEY</value>
</property>
<property>
  <name>fs.s3n.awsAccessKeyId</name>
  <value>$AWS_ACCESS_KEY_ID</value>
</property>
<property>
  <name>fs.s3n.awsSecretAccessKey</name>
  <value>$AWS_SECRET_ACCESS_KEY</value>
</property>
</configuration>
EOF

  cat > /etc/$HADOOP/conf.dist/fairscheduler.xml <<EOF
<?xml version="1.0"?>
<allocations>
</allocations>
EOF

  cat > /etc/$HADOOP/conf.dist/hadoop-metrics.properties <<EOF
# Exposes /metrics URL endpoint for metrics information.
dfs.class=org.apache.hadoop.metrics.spi.NoEmitMetricsContext
mapred.class=org.apache.hadoop.metrics.spi.NoEmitMetricsContext
jvm.class=org.apache.hadoop.metrics.spi.NoEmitMetricsContext
rpc.class=org.apache.hadoop.metrics.spi.NoEmitMetricsContext
EOF

  # Keep PID files in a non-temporary directory
  sed -i -e "s|# export HADOOP_PID_DIR=.*|export HADOOP_PID_DIR=/var/run/hadoop|" \
    /etc/$HADOOP/conf.dist/hadoop-env.sh
  mkdir -p /var/run/hadoop
  chown -R hadoop:hadoop /var/run/hadoop

  # Set SSH options within the cluster
  sed -i -e 's|# export HADOOP_SSH_OPTS=.*|export HADOOP_SSH_OPTS="-o StrictHostKeyChecking=no"|' \
    /etc/$HADOOP/conf.dist/hadoop-env.sh

  # Hadoop logs should be on the /mnt partition
  rm -rf /var/log/hadoop
  mkdir /mnt/hadoop/logs
  chown hadoop:hadoop /mnt/hadoop/logs
  ln -s /mnt/hadoop/logs /var/log/hadoop
  chown -R hadoop:hadoop /var/log/hadoop

  # Hadoop logs should be on the /mnt partition
  rm -rf /var/log/hadoop-0.20
  mkdir -p /mnt/hadoop-0.20/logs
  chown hadoop:hadoop /mnt/hadoop-0.20/logs
  ln -s /mnt/hadoop-0.20/logs /var/log/hadoop-0.20
  chown -R hadoop:hadoop /var/log/hadoop-0.20
}

function setup_web() {
  apt-get -y install thttpd
  WWW_BASE=/var/www

  cat > $WWW_BASE/index.html << END
<html>
<head>
<title>Hadoop EC2 Cluster</title>
</head>
<body>
<h1>Hadoop EC2 Cluster</h1>
To browse the cluster you need to have a proxy configured.
<ul>
<li><a href="http://$NN_HOST:50070/">NameNode</a>
<li><a href="http://$JT_HOST:50030/">JobTracker</a>
</ul>
</body>
</html>
END

  service thttpd start

}

function start_daemon() {
  apt-get -y install $HADOOP-$1
  service $HADOOP-$1 start
}

function start_namenode() {
  AS_HADOOP="su -s /bin/bash - hadoop -c"
  [ ! -e $FIRST_MOUNT/hadoop/hdfs ] && $AS_HADOOP "/usr/bin/$HADOOP namenode -format"

  start_daemon namenode

  $AS_HADOOP "$HADOOP dfsadmin -safemode wait"

  $AS_HADOOP "/usr/bin/$HADOOP fs -mkdir /user"
  $AS_HADOOP "/usr/bin/$HADOOP fs -chmod +w /user"

  $AS_HADOOP "/usr/bin/$HADOOP fs -mkdir /tmp"
  $AS_HADOOP "/usr/bin/$HADOOP fs -chmod +w /tmp"

  $AS_HADOOP "/usr/bin/$HADOOP fs -mkdir /user/hive/warehouse"
  $AS_HADOOP "/usr/bin/$HADOOP fs -chmod +w /user/hive/warehouse"
}

update_repo
install_user_packages
install_hadoop
configure_hadoop

for role in $(echo "$ROLES" | tr "," "\n"); do
  case $role in
  nn)
    setup_web
    start_namenode
    ;;
  snn)
    start_daemon secondarynamenode
    ;;
  jt)
    start_daemon jobtracker
    ;;
  dn)
    start_daemon datanode
    ;;
  tt)
    start_daemon tasktracker
    ;;
  esac
done
