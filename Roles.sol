// SPDX-License-Identifier: MIT
pragma solidity ^0.8.1;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";

contract Roles is Initializable, AccessControlUpgradeable, UUPSUpgradeable, PausableUpgradeable {
//OPCION1: misrety box con mapeo de claimed y se realiza una simple comparacion para que no revierta
    
    //Convert the string (a role) into a hash for a better flexibility
    mapping(string => bytes32) private roles;

    event eventWhitelist(
        address indexed roleAddress,
        string description
    );

    // Is the address that will collect the funds of the differents contracts
    address private collector;

    // Store addresses with privatesale role
    address [] private privateSaleWhitelistAddresses;

    // Store addresses with presale role
    address [] private preSaleWhitelistAddresses;

    // Store addresses with airdrop "role" & aidropClaimed "role"
    struct Airdrop {
        address [] airdropAddresses;
        address [] airdropClaimedAddresses;
        mapping(address => bool) airdropRoleMap;
        mapping(address => bool) airdropClaimedRoleMap;
    }

    // Map the contract address to the struct
    mapping(address => Airdrop) private contractAirdrop;

    mapping(address => uint256) public preSaleNftClaimed; //temporal

    function _onlyDefaultAdminMisteryBox() private view{
        require(hasRole(roles["MISTERY_BOX_ADDRESS"], msg.sender) || 
        hasRole(roles["DEFAULT_ADMIN_ROLE"], msg.sender), "Error, the address does not have an Mistery Box role or Default Admin role");
    }

    modifier onlyDefaultAdminMisteryBox {
        _onlyDefaultAdminMisteryBox();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() initializer {}

    function initialize(address _collector) initializer external {
        require(_collector != address(0),"The address cannot be the address 0");
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __Pausable_init();
        collector = _collector;

        //Roles
        roles["NFT_ADMIN_ROLE"] = keccak256("NFT_ADMIN_ROLE");
        roles["ARTIST_ROLE"] =  keccak256("ARTIST_ROLE");
        roles["PRESALE_WHITELIST"] = keccak256("PRESALE_WHITELIST");
        roles["PRIVATE_SALE_WHITELIST"] =  keccak256("PRIVATE_SALE_WHITELIST");
        roles["PRE_SALE_NFT_BUYER"] =  keccak256("PRE_SALE_NFT_BUYER");

        // Contracts
        roles["MISTERY_BOX_ADDRESS"] = keccak256("MISTERY_BOX_ADDRESS");
        roles["ICO_ADDRESS"] = keccak256("ICO_ADDRESS");        

        _setupRole(roles["NFT_ADMIN_ROLE"], msg.sender);
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /**
     * @dev Grants `role` to `account`.
     *
     * If `account` had not been already granted `role`, emits a {RoleGranted}
     * event.
     *
     * Requirements:
     *
     * - The caller must have ``role``'s admin role.
     * - The contract must not be paused.
     *
     */
    function grantRole(bytes32 role, address account) public virtual override whenNotPaused() {
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender) || hasRole(roles["NFT_ADMIN_ROLE"], msg.sender), "error in grant role");

        if(role == getHashRole("NFT_ADMIN_ROLE") || role == DEFAULT_ADMIN_ROLE){                                               
            require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "Only Default admin can grant NFT Admin role or Airdrop role");
        }

        _grantRole(role, account);
    }

    
    /**
     * @dev Revokes `role` from `account`.
     *
     * If `account` had been granted `role`, emits a {RoleRevoked} event.
     *
     * Requirements:
     *
     * - The caller must have ``role``'s admin role.
     * - The contract must not be paused.
     */
    function revokeRole(bytes32 role, address account) public virtual override whenNotPaused(){
        require(role != DEFAULT_ADMIN_ROLE, "Can't revoke default admin role");
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender)|| hasRole(roles["NFT_ADMIN_ROLE"], msg.sender), "error in revoke role");
        
        if(hasRole(role, msg.sender) == hasRole(role, account)){                              
            require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "Can't revoke same role");
        }
        
        _revokeRole(role, account);
    }

    
    /**
     *
     * @dev Create the hash of the string sent by parameter
     *
     * Requirements:
     *
     * - The caller must have ``role``'s admin role.
     * - The contract must not be paused.
     *
     */
    function createRole(string memory _roleName) external whenNotPaused() onlyRole(DEFAULT_ADMIN_ROLE) {
        roles[_roleName] = keccak256(abi.encodePacked(_roleName));
    }

    
    /**
     *
     * @dev Get the hash of the string sent by parameter
     *
     * The role must be previously included previously the mapping `roles` 
     *
     * To add a role in the mapping, use {createRole}.
     *
     */
    function getHashRole(string memory _roleName) public view returns(bytes32) {
        return roles[_roleName];
    }

    /**
     *
     * @dev Get the address array of the Private sale whitelist
     *
     *
     */

    function getPrivateSaleWhitelistAddresses() public view returns(address[] memory) {
        return privateSaleWhitelistAddresses;
    }


    /**
     *
     * @dev Get the address array of the Presale whitelist
     *
     */
    function getPreSaleWhitelistAddresses() public view returns(address[] memory) {
        return preSaleWhitelistAddresses;
    }


    /**
     *
     * @dev Get the address array of the airdrop
     *
     */
    function getAirdropAddresses(address _nftContract) public view returns(address[] memory) {
        return contractAirdrop[_nftContract].airdropAddresses;
    }


    /**
     *
     * @dev Get the address array of the airdropClaimed
     *
     */
    function getAirdropClaimedAddresses(address _nftContract) public view returns(address[] memory) {
        return contractAirdrop[_nftContract].airdropClaimedAddresses;
    }


    /**
     *
     * @dev Returns `true` if the `account` was added to the private sale
     *
     * To add an account to the private sale, use{addPrivateSaleWhitelist}
     *
     */
    function isPrivateWhitelisted(address _address) external view returns(bool){
        return hasRole(getHashRole("PRIVATE_SALE_WHITELIST"), _address);
    }


    /**
     *
     * @dev Returns `true` if the `account` was added to the presale
     *
     * To add an account to the presale, use{addPreSaleWhitelist}
     *
     */
    function isPreSaleWhitelisted(address _address) external view returns(bool){
        return hasRole(getHashRole("PRESALE_WHITELIST"), _address);
    }


    /**
     *
     * @dev Add an account to the private sale
     *
     * Requirements:
     *
     * - The caller must have ``role``'s admin role.
     * - The contract must not be paused.
     *
     */
    function addPrivateSaleWhitelist(address _address) external whenNotPaused() onlyRole(DEFAULT_ADMIN_ROLE)  {
        if(!hasRole(roles["PRIVATE_SALE_WHITELIST"], _address)){
            emit eventWhitelist(_address,"Add account to private sale");
            grantRole(roles["PRIVATE_SALE_WHITELIST"], _address);
            privateSaleWhitelistAddresses.push(_address);
        }
    }


   /**
     *
     * @dev Add an account to the presale
     *
     * Requirements:
     *
     * - The caller must have ``role``'s mistery box role.
     * - The contract must not be paused.
     *
     */
    function addPreSaleWhitelist(address _address) external whenNotPaused(){
        require(hasRole(roles["MISTERY_BOX_ADDRESS"], msg.sender), "Error, the address does not have an Mistery Box role"); 
        if(!hasRole(roles["PRESALE_WHITELIST"], _address)){
            emit eventWhitelist(_address,"Add account to presale");
            _grantRole(roles["PRESALE_WHITELIST"],_address);
            preSaleWhitelistAddresses.push(_address);
        }
    }


    /**
     *
     * @dev remove an account of the private sale
     *
     * Requirements:
     *
     * - The caller must have ``role``'s admin role.
     * - The contract must not be paused.
     *
     */
    function removePrivateSaleWhitelist(address _address, uint _index) external whenNotPaused() onlyRole(DEFAULT_ADMIN_ROLE) {
        emit eventWhitelist(_address,"remove account from private sale");
        privateSaleWhitelistAddresses[_index] = privateSaleWhitelistAddresses[privateSaleWhitelistAddresses.length-1];
        privateSaleWhitelistAddresses.pop();
        revokeRole(getHashRole("PRIVATE_SALE_WHITELIST"), _address);
    }


    /**
     *
     * @dev remove an account of the presale sale
     *
     * Requirements:
     *
     * - The caller must have ``role``'s admin role.
     * - The contract must not be paused.
     *
     */
    function removePreSaleWhitelist(address _address, uint _index) external whenNotPaused() onlyRole(DEFAULT_ADMIN_ROLE){
        emit eventWhitelist(_address,"remove account from presale");
        preSaleWhitelistAddresses[_index] = preSaleWhitelistAddresses[preSaleWhitelistAddresses.length-1];
        preSaleWhitelistAddresses.pop();
        revokeRole(getHashRole("PRESALE_WHITELIST"), _address);
    }

    /**
     *
     * @dev Get the collector address
     *
     */
    function getCollector() external view returns(address){
        return collector;
    }


    /**
     *
     * @dev Set the collector address
     *
     * Requirements:
     *
     * - The caller must have ``role``'s admin role.
     */
    function setCollector(address _collector) external whenNotPaused onlyRole(DEFAULT_ADMIN_ROLE){
        require(_collector != address(0));
        collector = _collector;
    }


    


    /**
     * @dev Gives `AirdropRole` to `account` in a nft colection.
     *
     * Requirements:
     *
     * - The caller must have ``role``'s default admin role.
     *
     */
    function addAirdropRole(address _nftContract, address _address) external onlyRole(DEFAULT_ADMIN_ROLE){
        if(!contractAirdrop[_nftContract].airdropRoleMap[_address]){
            Airdrop storage _mappingAirdropAux = contractAirdrop[_nftContract];
            _mappingAirdropAux.airdropAddresses.push(_address);
            _mappingAirdropAux.airdropRoleMap[_address] = true;
        }  
    }
     
    
    /**
     * @dev Gives `AirdropClaimedRole` to `account` in a nft colection.
     *
     * Requirements:
     *
     * - The caller must have ``role``'s default admin role or misterybox role.
     *
     */
    function addAirdropClaimedRole(address _nftContract, address _address) external onlyDefaultAdminMisteryBox{
        if(!contractAirdrop[_nftContract].airdropClaimedRoleMap[_address]){
            Airdrop storage _mappingAirdropAux = contractAirdrop[_nftContract];
            _mappingAirdropAux.airdropClaimedAddresses.push(_address);
            _mappingAirdropAux.airdropClaimedRoleMap[_address] = true;
        }
    }

    
    /**
     * @dev Removes `AirdropRole` from an `account` in a nft colection.
     *
     * Requirements:
     *
     * - The caller must have ``role``'s default admin role or misterybox role.
     *
     */
    function removeAirdropRole(address _nftContract, address _address, uint _index) external onlyDefaultAdminMisteryBox{

        address [] storage _arrayAirdrop = contractAirdrop[_nftContract].airdropAddresses;
        
        if(_arrayAirdrop.length == 1){
            _arrayAirdrop.pop();
            contractAirdrop[_nftContract].airdropRoleMap[_address] = false;
            return;
        }
        
        _arrayAirdrop[_index] = _arrayAirdrop[_arrayAirdrop.length-1];
        _arrayAirdrop.pop();
        contractAirdrop[_nftContract].airdropRoleMap[_address] = false;
    }


    /**
     * @dev Returns `true` if an `account` has AirdropRole.
     *
     */
    function hasAirdropRole(address _nftContract, address _address) external view returns(bool){
        return contractAirdrop[_nftContract].airdropRoleMap[_address];
    }


    /**
     * @dev Returns `true` if an `account` has already claimed his Airdrop.
     *
     */
    function hasAirdropClaimedRole(address _nftContract, address _address) external view returns(bool){
        return contractAirdrop[_nftContract].airdropClaimedRoleMap[_address];
    }

    /**
     *
     * @dev See {utils/UUPSUpgradeable-_authorizeUpgrade}.
     *
     * Requirements:
     *
     * - The caller must have ``role``'s admin role.
     *
     */
    function _authorizeUpgrade(address newImplementation)
        internal
        onlyRole(DEFAULT_ADMIN_ROLE)
        whenPaused()
        override
    {} 


    /**
     *
     * @dev See {utils/UUPSUpgradeable-upgradeTo}.
     *
     * Requirements:
     *
     * - The caller must have ``role``'s admin role.
     * - The contract must be paused 
     *
     */
    function upgradeTo(address newImplementation) external override onlyRole(DEFAULT_ADMIN_ROLE) whenPaused {
         _authorizeUpgrade(newImplementation);
        _upgradeToAndCallUUPS(newImplementation, new bytes(0), false);
    }


    /**
     *
     * @dev See {utils/UUPSUpgradeable-upgradeToAndCall}.
     *
     * Requirements:
     *
     * - The caller must have ``role``'s admin role.
     * - The contract must be paused 
     *
     */
    function upgradeToAndCall(address newImplementation, bytes memory data) external payable override onlyRole(DEFAULT_ADMIN_ROLE) whenPaused {
        _authorizeUpgrade( newImplementation);
        _upgradeToAndCallUUPS(newImplementation, data, true);
    }

    /**
     *
     * @dev See {security/PausableUpgradeable-_pause}.
     *
     * Requirements:
     *
     * - The caller must have ``role``'s admin role.
     *
     */
    function pause() external whenNotPaused onlyRole(DEFAULT_ADMIN_ROLE) {
        //Debería ser la misma persona la que deploya el contrato de roles y el de misteryBox
        _pause();
    }
    

   /**
     *
     * @dev See {security/PausableUpgradeable-_unpause}.
     *
     * Requirements:
     *
     * - The caller must have ``role``'s admin role.
     *
     */
    function unpause() external whenPaused onlyRole(DEFAULT_ADMIN_ROLE) {
        //Debería ser la misma persona la que deploya el contrato de roles y el de misteryBox
        _unpause();
    }

}