// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { FHE, euint32, ebool } from "@fhevm/solidity/lib/FHE.sol";
import { SepoliaConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract DynamicLaneManagementFHE is SepoliaConfig {
    struct EncryptedTrafficData {
        uint256 id;
        address sensor;
        euint32 encryptedVolume;         // Encrypted vehicle count
        euint32 encryptedAvgSpeed;        // Encrypted average speed
        euint32 encryptedDestination;     // Encrypted destination pattern
        euint32 encryptedCongestionLevel; // Encrypted congestion level
        uint256 timestamp;
    }
    
    struct LaneConfiguration {
        euint32 encryptedDirection;       // Encrypted lane direction (0=forward, 1=reverse)
        euint32 encryptedLaneCount;       // Encrypted number of lanes per direction
        euint32 encryptedFlowRate;        // Encrypted vehicles per hour
        uint256 timestamp;
    }
    
    struct DecryptedConfig {
        uint32 direction;
        uint32 laneCount;
        uint32 flowRate;
        bool isRevealed;
    }

    uint256 public dataCount;
    mapping(uint256 => EncryptedTrafficData) public trafficData;
    mapping(uint256 => LaneConfiguration) public laneConfigs;
    mapping(uint256 => DecryptedConfig) public decryptedConfigs;
    
    mapping(address => uint256[]) private sensorData;
    mapping(address => bool) private authorizedOperators;
    
    mapping(uint256 => uint256) private requestToConfigId;
    
    event DataReceived(uint256 indexed id, address indexed sensor);
    event LaneConfigUpdated(uint256 indexed id);
    event ConfigDecrypted(uint256 indexed id);
    
    address public trafficAdmin;
    
    modifier onlyAdmin() {
        require(msg.sender == trafficAdmin, "Not admin");
        _;
    }
    
    modifier onlyOperator() {
        require(authorizedOperators[msg.sender], "Not authorized");
        _;
    }
    
    constructor() {
        trafficAdmin = msg.sender;
    }
    
    /// @notice Authorize a traffic operator
    function authorizeOperator(address operator) public onlyAdmin {
        authorizedOperators[operator] = true;
    }
    
    /// @notice Submit encrypted traffic data
    function submitEncryptedTrafficData(
        euint32 encryptedVolume,
        euint32 encryptedAvgSpeed,
        euint32 encryptedDestination,
        euint32 encryptedCongestionLevel
    ) public {
        dataCount += 1;
        uint256 newId = dataCount;
        
        trafficData[newId] = EncryptedTrafficData({
            id: newId,
            sensor: msg.sender,
            encryptedVolume: encryptedVolume,
            encryptedAvgSpeed: encryptedAvgSpeed,
            encryptedDestination: encryptedDestination,
            encryptedCongestionLevel: encryptedCongestionLevel,
            timestamp: block.timestamp
        });
        
        sensorData[msg.sender].push(newId);
        emit DataReceived(newId, msg.sender);
    }
    
    /// @notice Calculate optimal lane configuration
    function calculateLaneConfiguration(uint256 dataId) public onlyOperator {
        EncryptedTrafficData storage data = trafficData[dataId];
        
        // Calculate directional demand
        euint32 forwardDemand = calculateDirectionalDemand(data, true);
        euint32 reverseDemand = calculateDirectionalDemand(data, false);
        
        // Determine lane direction
        ebool reverseDirection = FHE.gt(reverseDemand, forwardDemand);
        euint32 direction = FHE.cmux(reverseDirection, FHE.asEuint32(1), FHE.asEuint32(0));
        
        // Calculate number of lanes per direction
        euint32 totalLanes = FHE.asEuint32(4); // Total available lanes
        euint32 demandRatio = FHE.div(
            FHE.mul(totalLanes, reverseDirection ? reverseDemand : forwardDemand),
            FHE.add(forwardDemand, reverseDemand)
        );
        
        euint32 laneCount = FHE.add(
            FHE.div(demandRatio, FHE.asEuint32(2)),
            FHE.asEuint32(1) // Ensure at least one lane
        );
        
        // Calculate flow rate
        euint32 flowRate = calculateFlowRate(data, reverseDirection);
        
        laneConfigs[dataId] = LaneConfiguration({
            encryptedDirection: direction,
            encryptedLaneCount: laneCount,
            encryptedFlowRate: flowRate,
            timestamp: block.timestamp
        });
        
        emit LaneConfigUpdated(dataId);
    }
    
    /// @notice Request decryption of lane configuration
    function requestConfigDecryption(uint256 configId) public onlyOperator {
        require(!decryptedConfigs[configId].isRevealed, "Already decrypted");
        
        LaneConfiguration storage config = laneConfigs[configId];
        
        bytes32[] memory ciphertexts = new bytes32[](3);
        ciphertexts[0] = FHE.toBytes32(config.encryptedDirection);
        ciphertexts[1] = FHE.toBytes32(config.encryptedLaneCount);
        ciphertexts[2] = FHE.toBytes32(config.encryptedFlowRate);
        
        uint256 reqId = FHE.requestDecryption(ciphertexts, this.decryptLaneConfig.selector);
        requestToConfigId[reqId] = configId;
    }
    
    /// @notice Process decrypted lane configuration
    function decryptLaneConfig(
        uint256 requestId,
        bytes memory cleartexts,
        bytes memory proof
    ) public {
        uint256 configId = requestToConfigId[requestId];
        require(configId != 0, "Invalid request");
        
        LaneConfiguration storage lConfig = laneConfigs[configId];
        DecryptedConfig storage dConfig = decryptedConfigs[configId];
        require(!dConfig.isRevealed, "Already decrypted");
        
        FHE.checkSignatures(requestId, cleartexts, proof);
        
        (uint32 direction, uint32 laneCount, uint32 flowRate) = 
            abi.decode(cleartexts, (uint32, uint32, uint32));
        
        dConfig.direction = direction;
        dConfig.laneCount = laneCount;
        dConfig.flowRate = flowRate;
        dConfig.isRevealed = true;
        
        emit ConfigDecrypted(configId);
    }
    
    /// @notice Calculate directional demand
    function calculateDirectionalDemand(
        EncryptedTrafficData storage data,
        bool isForward
    ) private view returns (euint32) {
        // Demand based on volume and destination patterns
        euint32 volumeFactor = FHE.div(data.encryptedVolume, FHE.asEuint32(10));
        euint32 destinationFactor = FHE.div(
            FHE.mul(data.encryptedDestination, FHE.asEuint32(isForward ? 70 : 30)),
            FHE.asEuint32(100)
        );
        
        return FHE.add(volumeFactor, destinationFactor);
    }
    
    /// @notice Calculate flow rate
    function calculateFlowRate(
        EncryptedTrafficData storage data,
        ebool reverseDirection
    ) private view returns (euint32) {
        // Flow rate based on average speed and congestion
        euint32 speedFactor = FHE.mul(data.encryptedAvgSpeed, FHE.asEuint32(10));
        euint32 congestionFactor = FHE.sub(
            FHE.asEuint32(100),
            FHE.div(data.encryptedCongestionLevel, FHE.asEuint32(10))
        );
        
        euint32 baseFlow = FHE.div(
            FHE.mul(speedFactor, congestionFactor),
            FHE.asEuint32(100)
        );
        
        // Adjust for direction
        return FHE.cmux(
            reverseDirection,
            FHE.mul(baseFlow, FHE.asEuint32(120)), // Higher flow for reverse direction
            baseFlow
        );
    }
    
    /// @notice Detect traffic pattern changes
    function detectPatternChange(address sensor) public view returns (ebool) {
        uint256[] memory dataPoints = sensorData[sensor];
        if (dataPoints.length < 2) return FHE.asEbool(false);
        
        EncryptedTrafficData storage current = trafficData[dataPoints[dataPoints.length - 1]];
        EncryptedTrafficData storage previous = trafficData[dataPoints[dataPoints.length - 2]];
        
        euint32 volumeChange = FHE.sub(current.encryptedVolume, previous.encryptedVolume);
        euint32 speedChange = FHE.sub(current.encryptedAvgSpeed, previous.encryptedAvgSpeed);
        
        return FHE.or(
            FHE.gt(FHE.abs(volumeChange), FHE.asEuint32(20)),
            FHE.gt(FHE.abs(speedChange), FHE.asEuint32(10))
        );
    }
    
    /// @notice Calculate congestion impact
    function calculateCongestionImpact(uint256 dataId) public view returns (euint32) {
        EncryptedTrafficData storage data = trafficData[dataId];
        
        return FHE.div(
            FHE.mul(data.encryptedCongestionLevel, data.encryptedVolume),
            FHE.asEuint32(100)
        );
    }
    
    /// @notice Optimize lane allocation
    function optimizeLaneAllocation(uint256 dataId) public view returns (euint32) {
        EncryptedTrafficData storage data = trafficData[dataId];
        euint32 forwardDemand = calculateDirectionalDemand(data, true);
        euint32 reverseDemand = calculateDirectionalDemand(data, false);
        
        euint32 totalDemand = FHE.add(forwardDemand, reverseDemand);
        euint32 allocationRatio = FHE.div(
            FHE.mul(forwardDemand, FHE.asEuint32(100)),
            totalDemand
        );
        
        return allocationRatio;
    }
    
    /// @notice Predict peak traffic
    function predictPeakTraffic(address sensor) public view returns (euint32) {
        uint256[] memory dataPoints = sensorData[sensor];
        if (dataPoints.length == 0) return FHE.asEuint32(0);
        
        euint32 totalVolume = FHE.asEuint32(0);
        for (uint i = 0; i < dataPoints.length; i++) {
            totalVolume = FHE.add(totalVolume, trafficData[dataPoints[i]].encryptedVolume);
        }
        
        euint32 avgVolume = FHE.div(totalVolume, FHE.asEuint32(uint32(dataPoints.length)));
        return FHE.mul(avgVolume, FHE.asEuint32(120)); // 20% increase for peak
    }
    
    /// @notice Calculate travel time savings
    function calculateTravelTimeSavings(uint256 configId) public view returns (euint32) {
        LaneConfiguration storage config = laneConfigs[configId];
        EncryptedTrafficData storage data = trafficData[configId];
        
        euint32 baseTime = FHE.div(
            FHE.mul(data.encryptedCongestionLevel, FHE.asEuint32(60)),
            FHE.asEuint32(10)
        );
        
        euint32 optimizedTime = FHE.div(
            baseTime,
            FHE.div(config.encryptedFlowRate, FHE.asEuint32(100))
        );
        
        return FHE.sub(baseTime, optimizedTime);
    }
    
    /// @notice Get encrypted traffic data
    function getEncryptedTrafficData(uint256 dataId) public view returns (
        address sensor,
        euint32 encryptedVolume,
        euint32 encryptedAvgSpeed,
        euint32 encryptedDestination,
        euint32 encryptedCongestionLevel,
        uint256 timestamp
    ) {
        EncryptedTrafficData storage d = trafficData[dataId];
        return (
            d.sensor,
            d.encryptedVolume,
            d.encryptedAvgSpeed,
            d.encryptedDestination,
            d.encryptedCongestionLevel,
            d.timestamp
        );
    }
    
    /// @notice Get encrypted lane configuration
    function getEncryptedLaneConfig(uint256 configId) public view returns (
        euint32 encryptedDirection,
        euint32 encryptedLaneCount,
        euint32 encryptedFlowRate,
        uint256 timestamp
    ) {
        LaneConfiguration storage c = laneConfigs[configId];
        return (
            c.encryptedDirection,
            c.encryptedLaneCount,
            c.encryptedFlowRate,
            c.timestamp
        );
    }
    
    /// @notice Get decrypted lane configuration
    function getDecryptedConfig(uint256 configId) public view returns (
        uint32 direction,
        uint32 laneCount,
        uint32 flowRate,
        bool isRevealed
    ) {
        DecryptedConfig storage c = decryptedConfigs[configId];
        return (c.direction, c.laneCount, c.flowRate, c.isRevealed);
    }
    
    /// @notice Calculate environmental impact
    function calculateEnvironmentalImpact(uint256 dataId) public view returns (euint32) {
        EncryptedTrafficData storage data = trafficData[dataId];
        
        // Higher congestion leads to more emissions
        return FHE.mul(data.encryptedCongestionLevel, FHE.asEuint32(5));
    }
    
    /// @notice Adjust for special events
    function adjustForSpecialEvents(uint256 dataId, euint32 eventImpact) public onlyOperator {
        EncryptedTrafficData storage data = trafficData[dataId];
        
        // Adjust volume based on event impact
        data.encryptedVolume = FHE.add(
            data.encryptedVolume,
            FHE.div(eventImpact, FHE.asEuint32(10))
        );
    }
    
    /// @notice Calculate safety index
    function calculateSafetyIndex(uint256 dataId) public view returns (euint32) {
        EncryptedTrafficData storage data = trafficData[dataId];
        
        // Safety decreases with congestion and increases with average speed
        return FHE.sub(
            FHE.asEuint32(100),
            FHE.div(
                FHE.add(
                    data.encryptedCongestionLevel,
                    FHE.div(data.encryptedAvgSpeed, FHE.asEuint32(10))
                ),
                FHE.asEuint32(2)
            )
        );
    }
    
    /// @notice Optimize signal timing
    function optimizeSignalTiming(uint256 dataId) public view returns (euint32) {
        EncryptedTrafficData storage data = trafficData[dataId];
        
        // Signal timing based on volume and congestion
        euint32 baseTiming = FHE.asEuint32(60); // 60 seconds base cycle
        euint32 volumeAdjustment = FHE.div(data.encryptedVolume, FHE.asEuint32(10));
        euint32 congestionAdjustment = FHE.div(data.encryptedCongestionLevel, FHE.asEuint32(5));
        
        return FHE.add(
            baseTiming,
            FHE.add(volumeAdjustment, congestionAdjustment)
        );
    }
    
    /// @notice Calculate network efficiency
    function calculateNetworkEfficiency(uint256 configId) public view returns (euint32) {
        LaneConfiguration storage config = laneConfigs[configId];
        EncryptedTrafficData storage data = trafficData[configId];
        
        return FHE.div(
            FHE.mul(config.encryptedFlowRate, FHE.asEuint32(100)),
            data.encryptedVolume
        );
    }
    
    /// @notice Predict future demand
    function predictFutureDemand(address sensor) public view returns (euint32) {
        uint256[] memory dataPoints = sensorData[sensor];
        if (dataPoints.length < 3) return FHE.asEuint32(0);
        
        euint32 trend = FHE.asEuint32(0);
        for (uint i = 1; i < dataPoints.length; i++) {
            EncryptedTrafficData storage current = trafficData[dataPoints[i]];
            EncryptedTrafficData storage previous = trafficData[dataPoints[i-1]];
            
            trend = FHE.add(
                trend,
                FHE.sub(current.encryptedVolume, previous.encryptedVolume)
            );
        }
        
        euint32 avgTrend = FHE.div(trend, FHE.asEuint32(uint32(dataPoints.length - 1)));
        EncryptedTrafficData storage latest = trafficData[dataPoints[dataPoints.length - 1]];
        
        return FHE.add(latest.encryptedVolume, avgTrend);
    }
    
    /// @notice Calculate economic impact
    function calculateEconomicImpact(uint256 configId) public view returns (euint32) {
        euint32 timeSavings = calculateTravelTimeSavings(configId);
        
        // Economic value of time savings (simplified)
        return FHE.mul(timeSavings, FHE.asEuint32(30)); // $30 per hour value
    }
    
    /// @notice Implement adaptive control
    function implementAdaptiveControl(uint256 dataId) public onlyOperator {
        EncryptedTrafficData storage data = trafficData[dataId];
        
        // Adjust congestion level based on real-time data
        ebool highCongestion = FHE.gt(data.encryptedCongestionLevel, FHE.asEuint32(70));
        data.encryptedCongestionLevel = FHE.cmux(
            highCongestion,
            FHE.sub(data.encryptedCongestionLevel, FHE.asEuint32(10)),
            FHE.add(data.encryptedCongestionLevel, FHE.asEuint32(5))
        );
    }
    
    /// @notice Calculate public benefit
    function calculatePublicBenefit(uint256 configId) public view returns (euint32) {
        euint32 timeSavings = calculateTravelTimeSavings(configId);
        euint32 environmentalImpact = calculateEnvironmentalImpact(configId);
        euint32 economicImpact = calculateEconomicImpact(configId);
        
        return FHE.add(
            FHE.add(timeSavings, economicImpact),
            FHE.sub(FHE.asEuint32(100), environmentalImpact)
        );
    }
    
    /// @notice Detect anomaly
    function detectAnomaly(address sensor) public view returns (ebool) {
        uint256[] memory dataPoints = sensorData[sensor];
        if (dataPoints.length < 3) return FHE.asEbool(false);
        
        EncryptedTrafficData storage current = trafficData[dataPoints[dataPoints.length - 1]];
        EncryptedTrafficData storage previous = trafficData[dataPoints[dataPoints.length - 2]];
        
        euint32 volumeDiff = FHE.sub(current.encryptedVolume, previous.encryptedVolume);
        euint32 speedDiff = FHE.sub(current.encryptedAvgSpeed, previous.encryptedAvgSpeed);
        
        // Anomaly if volume increases while speed decreases significantly
        return FHE.and(
            FHE.gt(volumeDiff, FHE.asEuint32(50)),
            FHE.lt(speedDiff, FHE.asEuint32(-20))
        );
    }
    
    /// @notice Optimize for public transport
    function optimizeForPublicTransport(uint256 dataId) public onlyOperator {
        EncryptedTrafficData storage data = trafficData[dataId];
        
        // Prioritize public transport lanes during high congestion
        ebool highCongestion = FHE.gt(data.encryptedCongestionLevel, FHE.asEuint32(60));
        data.encryptedDestination = FHE.cmux(
            highCongestion,
            FHE.add(data.encryptedDestination, FHE.asEuint32(20)), // Increase public transport weighting
            data.encryptedDestination
        );
    }
    
    /// @notice Calculate resilience index
    function calculateResilienceIndex(uint256 dataId) public view returns (euint32) {
        EncryptedTrafficData storage data = trafficData[dataId];
        
        // Resilience decreases with congestion
        return FHE.sub(
            FHE.asEuint32(100),
            data.encryptedCongestionLevel
        );
    }
}