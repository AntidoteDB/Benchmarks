#!/bin/bash

AllNodes=$1
Cookie=$2
File="./"$3
Reads=$4
Writes=$5
NumDCs=$6
NodesPerDC=$7
DcId=$8

# if [ $File = "./examples/antidote_pb_crdt_orset.config" ]; then
#     Type="set"
# if [ $File = "./examples/antidote_pb_crdt_orset_big.config" ]; then
#     Type="set"
# if [ $File = "./examples/antidote_pb_riak_dt_orset.config" ]; then
#     Type="set"
# if [ $File = "./examples/antidote_pb_riak_dt_orset.config" ]; then
#     Type="set"
# else
#     Type="counter"
# fi
Type="counter"

sed -i '/antidote_pb_ips/d' $File 
sed -i '/concurrent/d' $File
## {operations, [{append, 1}, {read, 100}]}.
sed -i '/operations/d' $File
sed -i '/num_reads/d' $File
sed -i '/num_updates/d' $File

#{num_reads, 10}.
#{num_updates, 10}.

#PerNodeNum=5
#Thread=20

#if [ $NodesPerDC -gt 8 ]; then
#    PerNodeNum=10
#fi
#if [ $NodesPerDC -gt 20 ]; then
#    PerNodeNum=1
#fi


BenchConfig="{antidote_pb_ips, ["
for Node in $AllNodes
do
    Node=\'$Node\',
    BenchConfig=$BenchConfig$Node
    #Thread=$((Thread+PerNodeNum))
done

# Use static number of threads
Thread=40

BenchConfig=${BenchConfig::-1}"]}."
echo $BenchConfig
echo "$BenchConfig" >> $File
sed -i "5i {concurrent, $Thread}." $File

if [ $Type = "counter" ]; then
    sed -i "6i {operations, [{append, $Writes}, {read, $Reads}]}." $File
else
    sed -i "6i {operations, [{update, $Writes}, {read, $Reads}]}." $File
fi
#use just transactions.
#sed -i "6i {operations, [{txn, 1}]}." $File


if [ $Writes -eq 1 ]; then
    ReadTxn=50
    WriteTxn=50
elif [ $Writes -eq 10 ]; then
    ReadTxn=75
    WriteTxn=25
elif [ $Writes -eq 25 ]; then
    ReadTxn=90
    WriteTxn=10
elif [ $Writes -eq 50 ]; then
    ReadTxn=100
    WriteTxn=0
else
    ReadTxn=1
    WriteTxn=1
fi

sed -i "7i {num_reads, $ReadTxn}." $File
sed -i "7i {num_updates, $WriteTxn}." $File


sed -i '/key_generator/d' $File
#sed -i "3i {key_generator, {dc_bias, $NumDCs, $DcId, $NodesPerDC, 10000}}." $File
#Keys=$(($NodesPerDC * 1000))
Keys=100000000
sed -i "3i {key_generator, {pareto_int, $Keys}}." $File

sed -i '/antidote_pb_num_dcs/d' $File 
sed -i '/antidote_pb_nodes_per_dc/d' $File
sed -i '/antidote_pb_dc_id/d' $File
sed -i "7i {antidote_pb_num_dcs, $NumDCs}." $File
sed -i "8i {antidote_pb_nodes_per_dc, $NodesPerDC}." $File
sed -i "9i {antidote_pb_dc_id, $DcId}." $File


