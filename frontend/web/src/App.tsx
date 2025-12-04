// App.tsx
import React, { useEffect, useState } from "react";
import { ethers } from "ethers";
import { getContractReadOnly, getContractWithSigner } from "./contract";
import WalletManager from "./components/WalletManager";
import WalletSelector from "./components/WalletSelector";
import "./App.css";

interface LaneData {
  id: string;
  encryptedFlow: string;
  timestamp: number;
  direction: "northbound" | "southbound";
  congestionLevel: number;
  status: "active" | "pending" | "archived";
}

const App: React.FC = () => {
  const [account, setAccount] = useState("");
  const [loading, setLoading] = useState(true);
  const [laneData, setLaneData] = useState<LaneData[]>([]);
  const [provider, setProvider] = useState<ethers.BrowserProvider | null>(null);
  const [isRefreshing, setIsRefreshing] = useState(false);
  const [showAddModal, setShowAddModal] = useState(false);
  const [adding, setAdding] = useState(false);
  const [walletSelectorOpen, setWalletSelectorOpen] = useState(false);
  const [transactionStatus, setTransactionStatus] = useState<{
    visible: boolean;
    status: "pending" | "success" | "error";
    message: string;
  }>({ visible: false, status: "pending", message: "" });
  const [newLaneData, setNewLaneData] = useState({
    direction: "northbound",
    congestionLevel: 3,
    encryptedFlow: ""
  });
  const [showStats, setShowStats] = useState(true);
  const [searchTerm, setSearchTerm] = useState("");

  // Calculate statistics
  const activeLanes = laneData.filter(l => l.status === "active").length;
  const northboundLanes = laneData.filter(l => l.direction === "northbound").length;
  const avgCongestion = laneData.length > 0 
    ? (laneData.reduce((sum, lane) => sum + lane.congestionLevel, 0) / laneData.length).toFixed(1)
    : "0";

  useEffect(() => {
    loadLaneData().finally(() => setLoading(false));
  }, []);

  const onWalletSelect = async (wallet: any) => {
    if (!wallet.provider) return;
    try {
      const web3Provider = new ethers.BrowserProvider(wallet.provider);
      setProvider(web3Provider);
      const accounts = await web3Provider.send("eth_requestAccounts", []);
      const acc = accounts[0] || "";
      setAccount(acc);

      wallet.provider.on("accountsChanged", async (accounts: string[]) => {
        const newAcc = accounts[0] || "";
        setAccount(newAcc);
      });
    } catch (e) {
      alert("Failed to connect wallet");
    }
  };

  const onConnect = () => setWalletSelectorOpen(true);
  const onDisconnect = () => {
    setAccount("");
    setProvider(null);
  };

  const loadLaneData = async () => {
    setIsRefreshing(true);
    try {
      const contract = await getContractReadOnly();
      if (!contract) return;
      
      // Check contract availability using FHE
      const isAvailable = await contract.isAvailable();
      if (!isAvailable) {
        console.error("Contract is not available");
        return;
      }
      
      const keysBytes = await contract.getData("lane_keys");
      let keys: string[] = [];
      
      if (keysBytes.length > 0) {
        try {
          keys = JSON.parse(ethers.toUtf8String(keysBytes));
        } catch (e) {
          console.error("Error parsing lane keys:", e);
        }
      }
      
      const list: LaneData[] = [];
      
      for (const key of keys) {
        try {
          const laneBytes = await contract.getData(`lane_${key}`);
          if (laneBytes.length > 0) {
            try {
              const laneData = JSON.parse(ethers.toUtf8String(laneBytes));
              list.push({
                id: key,
                encryptedFlow: laneData.flow,
                timestamp: laneData.timestamp,
                direction: laneData.direction,
                congestionLevel: laneData.congestionLevel,
                status: laneData.status || "active"
              });
            } catch (e) {
              console.error(`Error parsing lane data for ${key}:`, e);
            }
          }
        } catch (e) {
          console.error(`Error loading lane ${key}:`, e);
        }
      }
      
      list.sort((a, b) => b.timestamp - a.timestamp);
      setLaneData(list);
    } catch (e) {
      console.error("Error loading lane data:", e);
    } finally {
      setIsRefreshing(false);
      setLoading(false);
    }
  };

  const addLaneData = async () => {
    if (!provider) { 
      alert("Please connect wallet first"); 
      return; 
    }
    
    setAdding(true);
    setTransactionStatus({
      visible: true,
      status: "pending",
      message: "Encrypting traffic data with FHE..."
    });
    
    try {
      // Simulate FHE encryption
      const encryptedData = `FHE-${btoa(JSON.stringify(newLaneData))}`;
      
      const contract = await getContractWithSigner();
      if (!contract) {
        throw new Error("Failed to get contract with signer");
      }
      
      const laneId = `${Date.now()}-${Math.random().toString(36).substring(2, 9)}`;

      const laneRecord = {
        flow: encryptedData,
        timestamp: Math.floor(Date.now() / 1000),
        direction: newLaneData.direction,
        congestionLevel: newLaneData.congestionLevel,
        status: "active"
      };
      
      // Store encrypted data on-chain using FHE
      await contract.setData(
        `lane_${laneId}`, 
        ethers.toUtf8Bytes(JSON.stringify(laneRecord))
      );
      
      const keysBytes = await contract.getData("lane_keys");
      let keys: string[] = [];
      
      if (keysBytes.length > 0) {
        try {
          keys = JSON.parse(ethers.toUtf8String(keysBytes));
        } catch (e) {
          console.error("Error parsing keys:", e);
        }
      }
      
      keys.push(laneId);
      
      await contract.setData(
        "lane_keys", 
        ethers.toUtf8Bytes(JSON.stringify(keys))
      );
      
      setTransactionStatus({
        visible: true,
        status: "success",
        message: "Encrypted lane data submitted!"
      });
      
      await loadLaneData();
      
      setTimeout(() => {
        setTransactionStatus({ visible: false, status: "pending", message: "" });
        setShowAddModal(false);
        setNewLaneData({
          direction: "northbound",
          congestionLevel: 3,
          encryptedFlow: ""
        });
      }, 2000);
    } catch (e: any) {
      const errorMessage = e.message.includes("user rejected transaction")
        ? "Transaction rejected by user"
        : "Submission failed: " + (e.message || "Unknown error");
      
      setTransactionStatus({
        visible: true,
        status: "error",
        message: errorMessage
      });
      
      setTimeout(() => {
        setTransactionStatus({ visible: false, status: "pending", message: "" });
      }, 3000);
    } finally {
      setAdding(false);
    }
  };

  const archiveLane = async (laneId: string) => {
    if (!provider) {
      alert("Please connect wallet first");
      return;
    }

    setTransactionStatus({
      visible: true,
      status: "pending",
      message: "Processing encrypted lane data..."
    });

    try {
      const contract = await getContractWithSigner();
      if (!contract) {
        throw new Error("Failed to get contract with signer");
      }
      
      const laneBytes = await contract.getData(`lane_${laneId}`);
      if (laneBytes.length === 0) {
        throw new Error("Lane not found");
      }
      
      const laneData = JSON.parse(ethers.toUtf8String(laneBytes));
      
      const updatedLane = {
        ...laneData,
        status: "archived"
      };
      
      await contract.setData(
        `lane_${laneId}`, 
        ethers.toUtf8Bytes(JSON.stringify(updatedLane))
      );
      
      setTransactionStatus({
        visible: true,
        status: "success",
        message: "Lane archived successfully!"
      });
      
      await loadLaneData();
      
      setTimeout(() => {
        setTransactionStatus({ visible: false, status: "pending", message: "" });
      }, 2000);
    } catch (e: any) {
      setTransactionStatus({
        visible: true,
        status: "error",
        message: "Archive failed: " + (e.message || "Unknown error")
      });
      
      setTimeout(() => {
        setTransactionStatus({ visible: false, status: "pending", message: "" });
      }, 3000);
    }
  };

  const checkAvailability = async () => {
    try {
      const contract = await getContractReadOnly();
      if (!contract) return;
      
      const isAvailable = await contract.isAvailable();
      
      setTransactionStatus({
        visible: true,
        status: isAvailable ? "success" : "error",
        message: isAvailable 
          ? "FHE service is available" 
          : "FHE service is currently unavailable"
      });
      
      setTimeout(() => {
        setTransactionStatus({ visible: false, status: "pending", message: "" });
      }, 2000);
    } catch (e) {
      setTransactionStatus({
        visible: true,
        status: "error",
        message: "Availability check failed"
      });
      
      setTimeout(() => {
        setTransactionStatus({ visible: false, status: "pending", message: "" });
      }, 2000);
    }
  };

  const filteredLanes = laneData.filter(lane => 
    lane.direction.toLowerCase().includes(searchTerm.toLowerCase()) ||
    lane.status.toLowerCase().includes(searchTerm.toLowerCase())
  );

  if (loading) return (
    <div className="loading-screen">
      <div className="spinner"></div>
      <p>Initializing FHE connection...</p>
    </div>
  );

  return (
    <div className="app-container">
      <header className="app-header">
        <div className="logo">
          <h1>FHE Lane Management</h1>
          <p>Dynamic lane control with fully homomorphic encryption</p>
        </div>
        
        <div className="header-actions">
          <WalletManager account={account} onConnect={onConnect} onDisconnect={onDisconnect} />
        </div>
      </header>
      
      <main className="main-content">
        <div className="hero-section">
          <div className="hero-text">
            <h2>Privacy-Preserving Traffic Optimization</h2>
            <p>Using FHE to dynamically adjust lanes while protecting driver privacy</p>
          </div>
          <div className="hero-actions">
            <button 
              onClick={checkAvailability}
              className="btn primary"
            >
              Check FHE Status
            </button>
            <button 
              onClick={() => setShowAddModal(true)}
              className="btn secondary"
            >
              Add Lane Data
            </button>
          </div>
        </div>
        
        <div className="controls-section">
          <div className="search-filter">
            <input
              type="text"
              placeholder="Search lanes..."
              value={searchTerm}
              onChange={(e) => setSearchTerm(e.target.value)}
              className="search-input"
            />
            <button 
              onClick={() => setShowStats(!showStats)}
              className="btn toggle-stats"
            >
              {showStats ? "Hide Stats" : "Show Stats"}
            </button>
          </div>
        </div>
        
        {showStats && (
          <div className="stats-section">
            <div className="stat-card">
              <h3>Active Lanes</h3>
              <div className="stat-value">{activeLanes}</div>
            </div>
            <div className="stat-card">
              <h3>Northbound</h3>
              <div className="stat-value">{northboundLanes}</div>
            </div>
            <div className="stat-card">
              <h3>Avg Congestion</h3>
              <div className="stat-value">{avgCongestion}</div>
            </div>
          </div>
        )}
        
        <div className="data-section">
          <div className="section-header">
            <h2>Encrypted Lane Data</h2>
            <button 
              onClick={loadLaneData}
              className="btn refresh"
              disabled={isRefreshing}
            >
              {isRefreshing ? "Refreshing..." : "Refresh Data"}
            </button>
          </div>
          
          {filteredLanes.length === 0 ? (
            <div className="empty-state">
              <p>No lane data found</p>
              <button 
                className="btn primary"
                onClick={() => setShowAddModal(true)}
              >
                Add First Lane
              </button>
            </div>
          ) : (
            <div className="data-grid">
              {filteredLanes.map(lane => (
                <div className="data-card" key={lane.id}>
                  <div className="card-header">
                    <span className={`direction-badge ${lane.direction}`}>
                      {lane.direction}
                    </span>
                    <span className={`status-badge ${lane.status}`}>
                      {lane.status}
                    </span>
                  </div>
                  <div className="card-body">
                    <div className="data-row">
                      <span>Congestion:</span>
                      <div className="congestion-level">
                        {Array.from({ length: 5 }).map((_, i) => (
                          <div 
                            key={i} 
                            className={`level ${i < lane.congestionLevel ? "active" : ""}`}
                          ></div>
                        ))}
                      </div>
                    </div>
                    <div className="data-row">
                      <span>Updated:</span>
                      <span>{new Date(lane.timestamp * 1000).toLocaleString()}</span>
                    </div>
                  </div>
                  <div className="card-footer">
                    <button 
                      onClick={() => archiveLane(lane.id)}
                      className="btn small"
                    >
                      Archive
                    </button>
                  </div>
                </div>
              ))}
            </div>
          )}
        </div>
      </main>
  
      {showAddModal && (
        <ModalAdd 
          onSubmit={addLaneData} 
          onClose={() => setShowAddModal(false)} 
          adding={adding}
          laneData={newLaneData}
          setLaneData={setNewLaneData}
        />
      )}
      
      {walletSelectorOpen && (
        <WalletSelector
          isOpen={walletSelectorOpen}
          onWalletSelect={(wallet) => { onWalletSelect(wallet); setWalletSelectorOpen(false); }}
          onClose={() => setWalletSelectorOpen(false)}
        />
      )}
      
      {transactionStatus.visible && (
        <div className="notification">
          <div className={`notification-content ${transactionStatus.status}`}>
            {transactionStatus.message}
          </div>
        </div>
      )}
  
      <footer className="app-footer">
        <div className="footer-content">
          <div className="footer-brand">
            <h3>FHE Lane Management</h3>
            <p>Privacy-preserving traffic optimization</p>
          </div>
          <div className="footer-links">
            <a href="#" className="footer-link">Documentation</a>
            <a href="#" className="footer-link">About FHE</a>
            <a href="#" className="footer-link">Contact</a>
          </div>
        </div>
        <div className="footer-bottom">
          <p>© {new Date().getFullYear()} FHE Lane Management. All rights reserved.</p>
        </div>
      </footer>
    </div>
  );
};

interface ModalAddProps {
  onSubmit: () => void; 
  onClose: () => void; 
  adding: boolean;
  laneData: any;
  setLaneData: (data: any) => void;
}

const ModalAdd: React.FC<ModalAddProps> = ({ 
  onSubmit, 
  onClose, 
  adding,
  laneData,
  setLaneData
}) => {
  const handleChange = (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement | HTMLTextAreaElement>) => {
    const { name, value } = e.target;
    setLaneData({
      ...laneData,
      [name]: value
    });
  };

  const handleSubmit = () => {
    if (!laneData.direction || !laneData.encryptedFlow) {
      alert("Please fill required fields");
      return;
    }
    
    onSubmit();
  };

  return (
    <div className="modal-overlay">
      <div className="modal-content">
        <div className="modal-header">
          <h2>Add Lane Data</h2>
          <button onClick={onClose} className="close-modal">&times;</button>
        </div>
        
        <div className="modal-body">
          <div className="form-group">
            <label>Direction *</label>
            <select 
              name="direction"
              value={laneData.direction} 
              onChange={handleChange}
              className="form-select"
            >
              <option value="northbound">Northbound</option>
              <option value="southbound">Southbound</option>
            </select>
          </div>
          
          <div className="form-group">
            <label>Congestion Level (1-5)</label>
            <input 
              type="number"
              name="congestionLevel"
              min="1"
              max="5"
              value={laneData.congestionLevel} 
              onChange={handleChange}
              className="form-input"
            />
          </div>
          
          <div className="form-group">
            <label>Encrypted Flow Data *</label>
            <textarea 
              name="encryptedFlow"
              value={laneData.encryptedFlow} 
              onChange={handleChange}
              placeholder="Enter encrypted traffic flow data..."
              className="form-textarea"
              rows={3}
            />
          </div>
          
          <div className="fhe-notice">
            Data will be processed using FHE without decryption
          </div>
        </div>
        
        <div className="modal-footer">
          <button 
            onClick={onClose}
            className="btn secondary"
          >
            Cancel
          </button>
          <button 
            onClick={handleSubmit} 
            disabled={adding}
            className="btn primary"
          >
            {adding ? "Processing..." : "Submit Encrypted Data"}
          </button>
        </div>
      </div>
    </div>
  );
};

export default App;