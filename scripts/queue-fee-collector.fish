set vexchange_factory 0xb312582c023cc4938cf0faea2fd609b46d7509a2
set fee_collector 0x5837dbaae7a739fbc264737920512efdf00af1ef

# Vexchange Factory
# function setPlatformFeeTo(address _platformFeeTo) external onlyOwner
set calldata (seth calldata "setPlatformFeeTo(address)" $fee_collector)

# determine eta
set now (date +%s)
set delay 172800  # 2 days in seconds
set eta (math $now + $delay + 300)  # 5 min margin of error

# Timelock
# function queueTransaction(address target, uint value, string memory signature, bytes memory data, uint eta) public returns (bytes32)
set queue_sig "queueTransaction(address,uint,string,bytes,uint)"
set exec_sig "executeTransaction(address,uint,string,bytes,uint)"
set queue_calldata (seth calldata $queue_sig $vexchange_factory 0 "[]" $calldata $eta)
set exec_calldata (seth calldata $exec_sig $vexchange_factory 0 "[]" $calldata $eta)

echo "queue_calldata: " $queue_calldata
echo "exec_calldata: " $exec_calldata
