// SPDX-License-Identifier: MIT
pragma solidity ^0.8.1;

import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts-upgradeable/utils/cryptography/draft-EIP712Upgradeable.sol";
import "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "./IRoles.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

import "hardhat/console.sol";

interface INft {
    function safeMint(
        address _to,
        string memory _uri,
        address _creator,
        string memory _moralisId
    ) external returns (uint256);

    function cost() external view returns (uint256);

    function perceptionCollection() external returns (bool);

    function revealed() external returns (bool);

    //payable(ngoAddress)
    function ngoAddress() external returns (address);

    function feeNgoPercent() external returns (uint256);
}

interface IOracle {
    function latestAnswer() external view returns (uint256);
}

/**
 * @title Interface to call QuickSwap Router
 * @dev Used to swap tokens
 */

interface UniswapV2Router02 {
    function swapExactETHForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory amounts);
}

/**
 * @notice Interface to call Recaudador contract.
 * @dev Checks buyers info.
 */

interface IRecaudador {
    function canRedeem(address beneficiary) external returns (bool);

    function nftRedeemed(address beneficiary) external;
}

contract MisteryBoxCollector is
    Initializable,
    PausableUpgradeable,
    UUPSUpgradeable,
    EIP712Upgradeable,
    ReentrancyGuardUpgradeable
{
    struct Nft {
        string _uri;
        address _signer;
        string _timeStamp;
        INft _nftContract;
    }

    struct arrayNft {
        Nft _nftData;
        bytes signature;
        string _moralisId;
    }

    /**
     * @notice Mapping from signature hash to boolean
     * @dev Indicate if the signature has already been used or not.
     */

    mapping(bytes => bool) private isMinted;

    /**
     * @notice Slippage used to swap the pay from a client to a stablecoin
     * @dev The range of this variable is 1 to 1000, were the value 1000 is equal to 100%. Inital value is set in 10 = 1% of slippage
     * {see if the visivility can be changed in an upgrade}
     */
    uint256 private slippagePorcentual;

    /**
     * @notice DEPRECATED
     * @dev DEPRECATED VARIABLE, isnt deleted because storage layout
     */
    address private oracleAddress;

    /**
     * @notice Address of the token used to swap the MATIC payed
     * @dev Token used for internal swap
     */
    address private TOKENADDRESS;

    /**
     * @notice Address of WMATIC
     * @dev address used in the router path to swap tokens
     */
    address private MATIC;

    /**
     * @notice DEPRECATED
     * @dev DEPRECATED VARIABLE, isnt deleted because storage layout
     */
    address private ROUTER;

    /**
     * @notice Address of Roles contract that manage access control
     * @dev This contract is used to grant roles and restrict some calls and access
     */
    address private rolesAddress;

    /**
     * @notice Mapping from pre-sale buyer address to amount of tokens claimed
     * @dev Counts the amount of tokens claimed by each buyer.
     * @return Returns the amount of tokens claimed by each buyer.
     */
    mapping(address => uint256) public nftsPresaleClaimed;

    /**
     * @notice Maximum amount of token to be claimed or buyed.
     * @return Returns the maximum amount of tokens that can be redeemed in total.
     */
    uint256 public maxNftAmountToReedem; // Cantidad total de nfts a vender

    /**
     * @notice Counts the amount of tokens claimed in total.
     * @dev This value increases every time a client buys or claims a token.
     */
    uint256 public maxNftAmountCounter; // Cantidad de nfts vendidos hasta el momento

    /**
     * @notice Address of Roles contract that manage access control
     * @dev This contract is used to grant roles and restrict some calls and access
     * @return roles the address of the Roles contract
     */
    IRoles public roles;

    /**
     * @notice DEPRECATED
     * @dev DEPRECATED VARIABLE, isnt deleted because storage layout
     */
    IOracle public _oracle;

    /**
     * @notice Address of a router to make a swap
     * @dev Used internally to swap a pay received in MATIC to USDC
     * @return router address of the router used
     */
    UniswapV2Router02 public _router;

    /**
     * @notice Instanciate Recaudador interface contract.
     * @dev Is it used to call the methods of the interface.
     */
    IRecaudador public recaudador;

    /**
     * @notice Oracle variable to check the price of MATIC
     * @dev Used to ask the MATIC price in usd and compute the value of a NFT
     */
    AggregatorV3Interface internal priceFeed; //variable a la cual se le envian transacciones del oraculo

    /**
     * @notice Maximum amount of nfts that can be redeemed in batch {preSaleNftRedeemBatch}
     * @dev Used to limit the amount of nfts that can be redeemed in batch.
     * @return Returns the maximum amount of nfts that can be redeemed in batch.
     */
    uint256 public maxMint;

    /**
     * @notice Amount of time the router has to make the swap before it expires and reverts.
     * @dev Used to increase the time of the swap.
     * @return Returns the amount of time in seconds unit.
     */
    uint256 public routerDeadline;

    /**
     * @dev Function with a require that allows access to a specific role
     */
    function _onlyDefaultAdmin() private view {
        require(
            roles.hasRole(roles.getHashRole("DEFAULT_ADMIN_ROLE"), msg.sender),
            "Error, the account is not the default admin"
        );
    }

    /**
     * @dev Modifier that calls a function that allows access to a specific role
     * Requirements:
     *
     * - The msg.sender must have DEFAULT_ADMIN_ROLE role
     */
    modifier onlyDefaultAdmin() {
        _onlyDefaultAdmin();
        _;
    }

    /**
     * @dev Function with a require that allows access to a specific role
     */
    function _onlyNftAdmin() private view {
        require(
            roles.hasRole(roles.getHashRole("NFT_ADMIN_ROLE"), msg.sender),
            "Error, the account is not the default admin"
        );
    }

    /**
     * @dev Modifier that calls a function that allows access to a specific role
     * Requirements:
     *
     * - The msg.sender must have NFT_ADMIN_ROLE role
     */
    modifier onlyNftAdmin() {
        _onlyDefaultAdmin();
        _;
    }

    /**
     * @notice Event emitted every time a client buys or claims a token.
     * @dev It is used to sync with the frontend.
     * @param moralisId moralis Id in the database.
     * @param revealed Indicates if the metadata of the nft is revealed or not.
     */
    event eventMint(string moralisId, bool revealed, uint256 tokenId);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() initializer {}

    /**
     * @notice Function that intializes the Proxy contract.
     * @dev Initalize the initial state of the contract
     * @param _rolesContracts  Address of the contract that manage access control in the app
     * @param _recaudador Address of the contract that manage the pre-sale of the tokens.
     * @param _nftAmount Maximum amount of tokens that can be redeemed in total.
     */
    function initialize(
        address _rolesContracts,
        address _recaudador,
        uint256 _nftAmount
    ) external initializer {
        __ReentrancyGuard_init();
        __EIP712_init("Mystery Box", "1.0.0");
        __UUPSUpgradeable_init();
        roles = IRoles(_rolesContracts);
        slippagePorcentual = 10; //0,5%
        oracleAddress = 0xAB594600376Ec9fD91F8e885dADF0CE036862dE0;
        TOKENADDRESS = 0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174;
        MATIC = 0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270;
        ROUTER = 0xa5E0829CaCEd8fFDD4De3c43696c57F7D7A678ff;
        _oracle = IOracle(oracleAddress);
        _router = UniswapV2Router02(ROUTER);
        recaudador = IRecaudador(_recaudador);
        priceFeed = AggregatorV3Interface(
            0xAB594600376Ec9fD91F8e885dADF0CE036862dE0
        );
        maxNftAmountToReedem = _nftAmount;
        maxNftAmountCounter = 0;
        rolesAddress = _rolesContracts;
        maxMint = 50;
        routerDeadline = 300;
    }

    /// @notice Claims the token through lazy mint
    /// @dev See {ArtNft-safeMint} & see {MisteryBoxCollector-_verify}.
    /// @param _nftData: struct with the data
    /// @param signature:signature of the nft
    /// @param _moralisId: Database ID
    /// @return uint256[] see {router-swapExactETHForTokens}
    function redeem(
        Nft memory _nftData,
        bytes calldata signature,
        string memory _moralisId
    ) external payable whenNotPaused nonReentrant returns (uint256[] memory) {
        require(
            maxNftAmountCounter < maxNftAmountToReedem,
            "There are no more NFTs"
        );

        require(
            msg.value >= computeAmount(address(_nftData._nftContract)),
            "Insufficient funds"
        );

        require(
            _verify(
                _nftData._signer,
                _hash(
                    _nftData._uri,
                    _nftData._signer,
                    address(_nftData._nftContract),
                    _nftData._timeStamp
                ),
                signature
            ),
            "Invalid signature"
        );
        require(!isMinted[signature], "This NFT was already minted");

        address _ngoAddress = _nftData._nftContract.ngoAddress();
        uint256 _ngoPercentage = _nftData._nftContract.feeNgoPercent();

        console.log("Ngo Address: ", _ngoAddress);
        console.log("Ngo Percentage: ", _ngoPercentage);

        // Supongo          precio nft = 100, fee percent = 10
        // 100 - (100* (100-10))/100 -> 100 - (9000/100) -> 100 - 90 -> 10 = feeNGO
        // 86 - ((86 * (100 - 20)) / 100) -> 86 - ((86 * 80) / 100) -> 86 - 6880 / 100 -> 86 - 68.8 -> 17.2 = feeNGO
        // uint256 feeNGO = msg.value -
        //     ((msg.value * (100 - _ngoPercentage)) / 100);

        uint256 feeNGO = (msg.value * _ngoPercentage) / 10000;

        console.log("Fee Ngo: ", feeNGO);

        (bool success1, ) = _ngoAddress.call{value: feeNGO}("");
        require(success1, "Send Matic to the NGO address failed");

        //86 - 17,2 (ejemplo)
        //uint256 _valueSwap = msg.value - feeNGO;

        uint256 costContract = _nftData._nftContract.cost();

        console.log("Cost contract : ", costContract);

        //uint256 costNGO = costContract - ((costContract * (100 - _ngoPercentage)) / 100);

        //uint256 _costSwap = costContract - costNGO;

        uint256[] memory amounts = _swapTokens(
            msg.value - feeNGO,
            (costContract -
                (costContract -
                    ((costContract * (10000 - _ngoPercentage)) / 10000)))
        );

        /* uint256[] memory amounts = _swapTokens(
            msg.value,
            _nftData._nftContract.cost()
        ); */

        uint256 tokenId = _nftData._nftContract.safeMint(
            msg.sender,
            _nftData._uri,
            _nftData._signer,
            _moralisId
        );

        isMinted[signature] = true;
        maxNftAmountCounter++;

        //Falso para los proyectos de 3ros
        if (_nftData._nftContract.perceptionCollection()) {
            roles.addPreSaleWhitelist(msg.sender);
        }

        emit eventMint(_moralisId, _nftData._nftContract.revealed(), tokenId);
        // Si reveal === true => que use el eventMint como antes
        // else => que no haga nada con este evento

        return amounts;
    }

    // Cada vez que se otorga el rol de Airdrop aumenta el contador para reservar los nfts y que no se vendan.
    function airdropCounter() external {
        // Que lo llamen del front cada vez que otorgamos el rol de Airdrop
        require(msg.sender == rolesAddress);
        require(
            maxNftAmountCounter < maxNftAmountToReedem,
            "There are no more NFTs"
        );
        maxNftAmountCounter++;
    }

    /**
     *
     * @dev See {ArtNft-safeMint} & see {MisteryBoxCollector-_verify}.
     *
     * Requirements:
     *
     * - The caller must have ``role``'s AIRDROP role.
     * - The contract must be unpaused
     */

    /// @notice redeem a nft with airdrop role
    /// @dev can redeem a nft when you have an airdrop role
    /// @param _nftData: struct with the data
    /// @param signature:signature of the nft
    /// @param _moralisId: Database ID
    /// @param _indexArrayRole: role
    function airdropRedeem(
        Nft memory _nftData,
        bytes calldata signature,
        string memory _moralisId,
        uint256 _indexArrayRole
    ) external whenNotPaused nonReentrant {
        require(
            roles.hasAirdropRole(address(_nftData._nftContract), msg.sender) ||
                roles.hasRole(
                    roles.getHashRole("NFT_ADMIN_ROLE"),
                    msg.sender
                ) ||
                roles.hasRole(
                    roles.getHashRole("DEFAULT_ADMIN_ROLE"),
                    msg.sender
                ),
            "Only airdrop role can call airdropRedeem"
        );

        if (roles.hasAirdropRole(address(_nftData._nftContract), msg.sender)) {
            roles.removeAirdropRole(
                address(_nftData._nftContract),
                msg.sender,
                _indexArrayRole
            );
            roles.addAirdropClaimedRole(
                address(_nftData._nftContract),
                msg.sender
            );
        }

        require(
            _verify(
                _nftData._signer,
                _hash(
                    _nftData._uri,
                    _nftData._signer,
                    address(_nftData._nftContract),
                    _nftData._timeStamp
                ),
                signature
            ),
            "Invalid signature"
        );

        require(!isMinted[signature], "This NFT was already minted");

        isMinted[signature] = true;
        uint256 tokenId = _nftData._nftContract.safeMint(
            msg.sender,
            _nftData._uri,
            _nftData._signer,
            _moralisId
        );
        emit eventMint(_moralisId, _nftData._nftContract.revealed(), tokenId); // CAMBIO en el evento
    }

    /// @notice redeem with relayer role
    /// @dev can redeem if you have a relayer role
    /// @param _nftData: struct with the data
    /// @param _moralisId: Database ID
    /// @param _toAddress: to address
    function relayerRedeem(
        Nft memory _nftData,
        bytes calldata signature,
        string memory _moralisId,
        address _toAddress,
        string memory _paymentId
    ) external whenNotPaused nonReentrant {
        require(
            roles.hasRole(roles.getHashRole("RELAYER_ROLE"), msg.sender),
            "Only relayer role can call relayerRedeem"
        );

        require(
            maxNftAmountCounter < maxNftAmountToReedem,
            "There are no more NFTs"
        );

        require(
            _verify(
                _nftData._signer,
                _hash(
                    _nftData._uri,
                    _nftData._signer,
                    address(_nftData._nftContract),
                    _nftData._timeStamp
                ),
                signature
            ),
            "Invalid signature"
        );

        require(!isMinted[signature], "This NFT was already minted");

        isMinted[signature] = true;
        uint256 tokenId = _nftData._nftContract.safeMint(
            _toAddress,
            _nftData._uri,
            _nftData._signer,
            _moralisId
        );
        emit eventMint(_moralisId, _nftData._nftContract.revealed(), tokenId); // CAMBIO en el evento
        maxNftAmountCounter++;
    }

    /**
     
     * @dev See {ArtNft-safeMint} & see {MisteryBoxCollector-_verify}.
     *
     * Requirements:
     *
     * - The caller must have ``role``'s PRE_SALE_NFT_BUYER role.
     * - The contract must be unpaused 
     */

    //El front debería chequear que quiere reclamar la cantidad que compró o menos de las que puede reclamar

    function preSaleNftRedeemBatch(arrayNft[] memory _nftDataArray)
        external
        whenNotPaused
        nonReentrant
    {
        require(
            roles.hasRole(roles.getHashRole("PRE_SALE_NFT_BUYER"), msg.sender),
            "Only pre-sale nft buyer can call airdropRedeem"
        );

        uint256 length = _nftDataArray.length;
        uint256 i = 0;
        length = (length > maxMint) ? maxMint : length; // Seteamos el que es menor

        while (i < length) {
            require(
                maxNftAmountCounter < maxNftAmountToReedem,
                "There are no more NFTs"
            );

            if (!recaudador.canRedeem(msg.sender)) {
                roles.revokeRole(
                    roles.getHashRole("PRE_SALE_NFT_BUYER"),
                    msg.sender
                );
                return;
            }

            arrayNft memory iNft = _nftDataArray[i];

            require(
                _verify(
                    iNft._nftData._signer,
                    _hash(
                        iNft._nftData._uri,
                        iNft._nftData._signer,
                        address(iNft._nftData._nftContract),
                        iNft._nftData._timeStamp
                    ),
                    iNft.signature
                ),
                "Invalid signature"
            );

            require(!isMinted[iNft.signature], "This NFT was already minted");

            isMinted[iNft.signature] = true;
            uint256 tokenId = iNft._nftData._nftContract.safeMint(
                msg.sender,
                iNft._nftData._uri,
                iNft._nftData._signer,
                iNft._moralisId
            );
            recaudador.nftRedeemed(msg.sender);
            maxNftAmountCounter++;

            if (iNft._nftData._nftContract.perceptionCollection()) {
                roles.addPreSaleWhitelist(msg.sender);
            }

            emit eventMint(
                iNft._moralisId,
                iNft._nftData._nftContract.revealed(),
                tokenId
            ); // CAMBIO en el evento

            i++;
        }

        if (!recaudador.canRedeem(msg.sender)) {
            roles.revokeRole(
                roles.getHashRole("PRE_SALE_NFT_BUYER"),
                msg.sender
            );
        }
    }

    /**
     * @notice Function so the owner can change the slippage
     * @dev See slippagePorcentual state variable to check the scale
     * @param newSlippage value of the new slippage to make the swap
     */
    function setSlippage(uint256 newSlippage) external onlyDefaultAdmin {
        slippagePorcentual = newSlippage;
    }

    /**
     * @notice Function to set the max amount of NFTs that can be minted per batch
     * @dev Set the max amount of NFTs that can be minted per batch.
     * @param _maxMint value of the new max amount of NFTs to mint per batch
     * Requirements:
     *
     * - The caller must have ``role``'s nft admin role.
     * - The contract must not be paused
     *
     */
    function setMaxMint(uint256 _maxMint) external onlyDefaultAdmin {
        maxMint = _maxMint;
    }

    /* Funcion que cambia los matic que vale un NFT por USDC y los transfiere a la wallet Recaudadora 
    param:
        _nftPrice: valor de un Nft en matic expresado en weis
    global:
    usdPrice: precio de un NFT en dolares expresado en weis seteado inicialmente
     */
    function _swapTokens(uint256 _purchaseValue, uint256 _nftPrice)
        internal
        returns (uint256[] memory)
    {
        uint256 usdcAmount = _nftPrice / 10**12; //debemos convertir amountUsdcOutMin a 6 decimales para poder comparar con amounts[1] que es el monto que realmente sale
        // Amount with a % substracted
        uint256 amountUsdcOutMin = usdcAmount -
            ((usdcAmount * slippagePorcentual) / 1000);
        //path for the router
        address[] memory path = new address[](2);
        path[1] = TOKENADDRESS; //usdc address
        path[0] = MATIC; //wMatic address
        //amount out is in 6 decimals
        console.log(
            "Dentro de swap tokens el valor de la compra es: ",
            _purchaseValue
        );
        console.log("Dentro de swap tokens el valor del nft es: ", _nftPrice);

        uint256[] memory amounts = _router.swapExactETHForTokens{
            value: _purchaseValue
        }(
            amountUsdcOutMin,
            path,
            roles.getCollector(),
            block.timestamp + routerDeadline
        );
        return amounts; //monto que se transfiere
    }

    /**
     * @notice Function to check the current matic price
     * @dev External call to the price feed, the return amount is represented in 8 decimals
     * @return Documents the price of 1 MATIC in USD
     */
    function getLatestPrice() public view returns (uint256) {
        (
            ,
            /*uint80 roundID*/
            int256 price, /*uint startedAt*/ /*uint timeStamp*/ /*uint80 answeredInRound*/
            ,
            ,

        ) = priceFeed.latestRoundData();
        return uint256(price);
    }

    /**
     * @notice Compute the price in matic of 1 NFT
     * @dev uses the state variable usdPrice with the price feed to compute the price of a NFT
     * @param _collectionAddress Address of the contract that the price is to be fetched
     * @return uint256 the price of a NFT in matic in weis
     */
    function computeAmount(address _collectionAddress)
        public
        view
        returns (uint256)
    {
        return ((INft(_collectionAddress).cost() * (10**8)) / getLatestPrice());
    }

    /**
     *
     * @dev See {draft-EIP712-_hashTypedDataV4}.
     *
     */

    function _hash(
        string memory _uri,
        address _signer,
        address _nftContract,
        string memory _timeStamp
    ) internal view returns (bytes32) {
        return
            _hashTypedDataV4(
                keccak256(
                    abi.encode(
                        keccak256(
                            "NFT(string _uri,address _signer,address _nftContract,string _timeStamp)"
                        ),
                        keccak256(bytes(_uri)),
                        _signer,
                        _nftContract,
                        keccak256(bytes(_timeStamp))
                    )
                )
            );
    }

    /**
     *
     * @dev See {SignatureChecker-isValidSignatureNow}.
     *
     */

    function _verify(
        address signer,
        bytes32 digest,
        bytes memory signature
    ) internal view returns (bool) {
        return SignatureChecker.isValidSignatureNow(signer, digest, signature);
    }

    /**
     *
     * @dev See {security/PausableUpgradeable-_pause}.
     *
     * Requirements:
     *
     * - The caller must have ``role``'s admin role.
     * - The contract must be paused
     *
     */

    function pause() external whenNotPaused onlyDefaultAdmin {
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
     * - The contract must be unpaused
     *
     */

    function unpause() external whenPaused onlyDefaultAdmin {
        //Debería ser la misma persona la que deploya el contrato de roles y el de misteryBox
        _unpause();
    }

    /**
     *
     * @dev See {utils/UUPSUpgradeable-_authorizeUpgrade}.
     *
     * Requirements:
     *
     * - The caller must have ``role``'s admin role.
     * - The contract must be paused
     *
     */

    function _authorizeUpgrade(address newImplementation)
        internal
        override
        whenPaused
        onlyDefaultAdmin
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

    function upgradeTo(address newImplementation)
        external
        override
        onlyDefaultAdmin
        whenPaused
    {
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

    function upgradeToAndCall(address newImplementation, bytes memory data)
        external
        payable
        override
        onlyDefaultAdmin
        whenPaused
    {
        _authorizeUpgrade(newImplementation);
        _upgradeToAndCallUUPS(newImplementation, data, true);
    }

    /// @notice set MaxNftAmount
    /// @dev Set the maximum amount of nfts to redeem
    /// @param _newAmount: uint256 that contains the maximum amount of nfts to redeee
    function setMaxNftAmount(uint256 _newAmount) external onlyDefaultAdmin {
        require(_newAmount > 0, "Amount is 0");
        maxNftAmountToReedem = _newAmount;
    }

    /// @notice Set the router deadline
    /// @dev Pass an uint256 that is the new Deadline
    /// @param _newDeadline: the new deadline in timestamp format
    function setRouterDeadline(uint256 _newDeadline) external onlyNftAdmin {
        require(_newDeadline > 0, "Deadline must be > 0");
        routerDeadline = _newDeadline;
    }

    /// @notice Set the max Nft Amount
    /// @dev Pass an uint256 that is the new amount
    /// @param _newAmount Is the new maximum amount of nfts
    function setMaxNftAmountCounter(uint256 _newAmount) external onlyNftAdmin {
        maxNftAmountCounter = _newAmount;
    }
}
