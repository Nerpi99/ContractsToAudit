// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@openzeppelin/contracts-upgradeable/token/ERC721/IERC721Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "./IRoles.sol";

import "hardhat/console.sol";

interface IPriceFeed {
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
}

interface INft {
    /**
     * @notice Royalty fee of the erc721 collection
     * @dev See {contracts-upgradeable - IERC2981Upgradeable}
     * @return returns the erc721 collection royalty fee. Example: 100 is 1%fee (100/100 = 1)
     */
    function royaltyFee() external view returns (uint256);

    function royaltyInfo(uint256, uint256) external returns (address, uint256);

    function supportsInterface(bytes4 interfaceID) external view returns (bool);

    function perceptionCollection() external returns (bool);

    function ngoAddress() external view returns (address);

    function feeNgoPercent() external view returns (uint256);
}

contract Marketplace is
    Initializable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    OwnableUpgradeable,
    PausableUpgradeable
{
    //Account to which the fee is granted.
    address payable public feeAccount;

    // Item counter in the marketplace
    // Fulfills the same function as the tokencounter of the collections (ERC721)
    // start at 1
    uint256 public itemCount;

    // Array with the ids of the created elements
    // Only item ids are pushed as they are created.
    // At no time is the order of the array altered
    uint256[] public itemArray;

    // Boolean used to find out if the contract allows the sale of any contract
    // - Or only the contracts that are of perception
    // If the variable is set to true, any contract is allowed.
    // Case of setting to false, only the sale of collections of perception is allowed
    bool public allContratsAllowed;

    /**
     * @notice Address of Roles contract that manage access control
     * @dev This contract is used to grant roles and restrict some calls and access
     */
    IRoles public rolesContract; //Al ser publica ya tiene su getter

    //Id of the erc2981 interface for the supportinterface check
    bytes4 private constant _INTERFACE_ID_ERC2981 = 0x2a55205a;

    /// @notice Oracle variable to check the price of MATIC
    /// @dev Used to ask the MATIC price in usd and compute the value of a NFT
    /// @return priceFeed return the address of the oracle
    address public priceFeed;

    /// @notice Used to format the price of the nfts to 18 decimals
    /// @dev See purchaseItems()
    /// @return oracleFactor
    uint256 public oracleFactor;

    //Structure that stores the data for the purchase/sale
    // It is stored to which collection it belongs, its tokenid, the price, the seller,
    // if the item was sold and if it is active or not
    struct Item {
        uint256 itemId; // id del item
        IERC721Upgradeable nftContract; // interfaz del standar 721
        uint256 tokenId; // id del nft
        uint256 price; // precio del nft seteado en weis USD. A la hora de comprar se realiza la conversion a matic
        address payable seller; // direccion del vendedor
        bool sold; // Si se vendió o no
        bool active; // si la venta esta activa o no
    }

    //Structure in charge of warehouses the fee and the status of an external collection
    struct CollectionStruct {
        address collectionAddress;
        uint256 feePercentaje;
        bool active;
    }

    //Map the item number with his Item structure
    mapping(uint256 => Item) public itemsPerNftId;

    //Map the wallet with the items it has created
    mapping(address => uint256[]) public itemsPerAccount;

    //Map the collections with the fee they are going to charge.
    mapping(address => CollectionStruct) public collectionInfo;

    // Array that is responsible for storing the addresses of the collections that
    //can be allowed within the market
    address[] public collectionAddressArray;

    //Event that is used when an item is OFFERED in the marketplace
    event Offered(
        uint256 itemId,
        address indexed nft,
        uint256 tokenId,
        uint256 price,
        address indexed seller
    );

    //Event that is used when an item is PURCHASED in the marketplace
    event Bought(
        uint256 itemId,
        address indexed nft,
        uint256 tokenId,
        uint256 price,
        address indexed seller,
        address indexed buyer
    );

    //Event that is emitted when the state of an item is modified
    event StatusItem(
        uint256 itemId,
        address indexed nft,
        uint256 tokenId,
        address indexed seller,
        bool active
    );

    //Event that is emitted when the price of an item is changed
    event PriceChanged(uint256 itemId, uint256 newPrice);

    //Event that is emitted when a collection is deleted
    event DeleteCollection(address collectionAddress);

    // checks if msg.sender is the item seller
    modifier onlyItemSeller(uint256 _itemId) {
        _onlyItemSeller(_itemId);
        _;
    }

    // checks if msg.value is bigger than 0
    modifier greaterThan0(uint256 _value) {
        _greaterThan0(_value);
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() initializer {}

    // Se encarga de chequear si el msg sender es el creador(vendedor) del item
    function _onlyItemSeller(uint256 _itemId) internal view {
        require(
            itemsPerNftId[_itemId].seller == msg.sender,
            "Only item seller"
        );
    }

    // Se encarga de chequear si el valor enviado es mayor a 0
    function _greaterThan0(uint256 _value) internal pure {
        require(_value > 0, "Must be greather than 0");
    }

    /**
     * @dev Function with a require that allows access to a specific role
     */
    function _onlyDefaultAdmin() private view {
        require(
            rolesContract.hasRole(
                rolesContract.getHashRole("DEFAULT_ADMIN_ROLE"),
                msg.sender
            ),
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
            rolesContract.hasRole(
                rolesContract.getHashRole("NFT_ADMIN_ROLE"),
                msg.sender
            ),
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
     * @dev The contract must be perception or must be allowed and active
     */
    function _onlyContractsAllowed(address _nftContract) private{
        
        bytes memory _data = abi.encodeWithSignature("perceptionCollection()");

        (bool success, ) = address(_nftContract).call(_data);

        bool isPerceptionCollection = false;

        if(success){
            isPerceptionCollection = (INft(address(_nftContract)).perceptionCollection());
            //console.log("Es perception collection: ",isPerceptionCollection);
        }

        require(
                isPerceptionCollection || // que sea de perception O
                    ((collectionInfo[address(_nftContract)].active) &&
                        rolesContract.hasRole(
                            keccak256("COLLECTIONS_ALLOWED"),
                            address(_nftContract)
                        )), //check if item is already active
                "Only Collection allowed"
        );
    }

    /**
     * @dev Modifier that calls a function that allows access to functions: makeItem and purchaseItem
     */
    modifier onlyContractsAllowed(address _nftContract) {
        _onlyContractsAllowed(_nftContract);
        _;
    }

    //Inicializo el proxy
    //_feePercent es el porcentaje que se va a llevar la wallet correspondiente (8% = 8)
    //_feeAccount es la cuenta que se va a llevar el fee de cada venta en el marketplace
    //_priceFeed es la direccion del oraculo que se utiliza para chequear el precio del matic
    //_rolesContracts es el contrato de roles para poder realizar los chequeos para las colecciones perception
    function initialize(
        address _feeAccount,
        address _priceFeed,
        address _rolesContracts,
        bool _allContratsAllowed
    ) external initializer {
        __Pausable_init();
        __Ownable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        feeAccount = payable(_feeAccount);
        priceFeed = _priceFeed;
        oracleFactor = 10**8;
        rolesContract = IRoles(_rolesContracts);
        allContratsAllowed = _allContratsAllowed;
    }

    //Se encarga de crear el item dentro del marketplace
    //Se envia el contrato de la colección de la cual se enviara el nft al marketplace
    //(previamente es necesario otorgarle los permisos al marketplace con approve desde la colección)
    //Se aprueba el token al marketplace y luego de desenlistar el item aprobas al address0

    //Se envia el id del token a vender
    //Se envia _price, el precio del nft en weis
    /// @notice create an item in marketplace
    /// @dev offer an item in markeplace
    /// @param _nftContract: nft contract
    /// @param _tokenId: token id
    /// @param _price: nft price
    function makeItem(
        IERC721Upgradeable _nftContract,
        uint256 _tokenId,
        uint256 _price
    ) external greaterThan0(_price) nonReentrant onlyContractsAllowed(address(_nftContract)){

        require(
            _nftContract.ownerOf(_tokenId) == msg.sender ||
                _nftContract.isApprovedForAll(
                    _nftContract.ownerOf(_tokenId),
                    msg.sender
                ),
            "Not owner nor approved for all"
        );

        itemCount++;

        itemsPerNftId[itemCount] = Item(
            itemCount, //itemId
            _nftContract, //nftContract
            _tokenId, //tokenId
            _price, //price
            payable(_nftContract.ownerOf(_tokenId)), //seller
            false, //sold
            true //active
        ); 

        //offered event
        emit Offered(
            itemCount,//itemId
            address(_nftContract),//nftContract
            _tokenId,//tokenId
            _price,//price
            msg.sender//seller
        );

        //push id to mappin
        uint256[] storage itemsInAccount = itemsPerAccount[msg.sender];

        itemArray.push(itemCount);

        itemsInAccount.push(itemCount);
    }

    /// @notice Function to check the current matic price
    /// @dev External call to the price feed, the return amount is represented in 8 decimals
    /// @return Documents the price of 1 MATIC in USD
    function getLatestPrice() public view returns (uint256) {
        (
            ,
            /*uint80 roundID*/
            int256 price, /*uint startedAt*/ /*uint timeStamp*/ /*uint80 answeredInRound*/
            ,
            ,

        ) = IPriceFeed(priceFeed).latestRoundData();
        return uint256(price);
    }

    /// @notice compute the price of nft in fiat
    /// @dev receives nft id and compute the price with the oracle
    /// @param _itemId: nft id
    /// @return the price of a nft in MATIC/USDC

    function computeAmount(uint256 _itemId) public view returns (uint256) {
        return ((itemsPerNftId[_itemId].price * oracleFactor) /
            getLatestPrice());
    }

    // ((INft(_collectionAddress).cost() * (10**8)) / getLatestPrice());

    /// @notice function to purchase a nft
    /// @dev payable function, receives an id of the nft that the client wants to purchase. Then checks if the msg.value is greater than nft price.
    /// @param _itemId: nft id

    function purchaseItem(uint256 _itemId) external payable nonReentrant onlyContractsAllowed(address(itemsPerNftId[_itemId].nftContract)){
        //Elegimos el Método de resta

        //TODO
        //Caso resta. Al dueño del nft le llega el (total - %fees)

        // Precio item
        // Fee contrato -> en base al precio del item
        // Fee artista -> en base al precio del item

        // Precio total = 100, fee contrato = 10%, fee artista = 2%.
        // 100                  - 10                - 2     = 100 Total a pagar
        //                                                  87 -> Que le llega al dueño
        //                                                  10 -> Le llega a la cuenta del marketplace
        //                                                  2 -> Le llega al artista
        //                                                  1-> le llega a la ONG

        require(
            _itemId > 0 && _itemId <= itemCount,
            "El item debe ser mayor a 0 y menor al contador"
        );

        Item storage item = itemsPerNftId[_itemId];

        uint256 itemPrice = computeAmount(_itemId);

        require(msg.value >= itemPrice, "Low msg.value");
        require(!item.sold && item.active, "Item sold or item inactive");

        // console.log("ItemPrice: ", itemPrice);
        // console.log("msg value: ", msg.value);

        //Levanto la estructura de la coleccion

        CollectionStruct memory _contractInfo = collectionInfo[
            address(item.nftContract)
        ];

        //Dinero al Artista (En caso de soportar la interfaz)
        address walletArtista = address(0);
        uint256 feeArtista = 0;

        if (
            INft(address(item.nftContract)).supportsInterface(
                _INTERFACE_ID_ERC2981
            )
        ) {
            (walletArtista, feeArtista) = INft(address(item.nftContract))
                .royaltyInfo(item.tokenId, itemPrice);
        }

        //Fee de la coleccion
        // uint256 _collectionFee = _contractInfo.feePercentaje;

        // Supongo          item price = 100, fee percent DE LA COLECCIÓN = 10
        // 100 - (100* (100-10))/100 -> 100 - (9000/100) -> 100 - 90 -> 10 = feeMarketPlace
        /* uint256 feeMarketPlace = itemPrice -
            ((itemPrice * (100 - _contractInfo.feePercentaje)) / 100);
 */
        uint256 feeMarketPlace = (itemPrice * _contractInfo.feePercentaje) /
            10000;

        console.log("FeeMarketplace: ", feeMarketPlace);

        uint256 feeNGOpercent = (itemPrice *
            (INft(address(item.nftContract)).feeNgoPercent())) / 10000;

        /* console.log("itemPrice", itemPrice);
        console.log("feeNGOpercent: ", feeNGOpercent);
        console.log("FEE: ", INft(address(item.nftContract)).feeNgoPercent()); */

        (bool success, ) = item.seller.call{
            value: itemPrice - feeMarketPlace - feeArtista - feeNGOpercent
        }("");
        require(success, "Send Matic to the seller failed");
        /*  console.log(
            "Fee que le llega al vendedor: ",
            (item.price - feeMarketPlace - feeArtista)
        ); */

        (bool success1, ) = feeAccount.call{value: feeMarketPlace}("");
        require(success1, "Send Matic to the Fee Account failed");
        /* console.log("Fee que le llega al Marketplace: ", feeMarketPlace); */

        //artist fee
        if (walletArtista != address(0)) {
            (bool success3, ) = payable(walletArtista).call{value: feeArtista}(
                ""
            );
            require(success3, "Send Matic to Artist failed");
            /* console.log("Fee que le llega al artista: ", feeArtista); */
        }

        transferOng(address(item.nftContract), feeNGOpercent);

        item.sold = true;
        item.nftContract.transferFrom(item.seller, msg.sender, item.tokenId);
        item.active = false;

        emit Bought(
            _itemId,
            address(item.nftContract),
            item.tokenId,
            item.price,
            item.seller,
            msg.sender
        );
    }


    /// @notice low level call that transfer the fee to NGO address
    /// @dev check if the nft contract has ngo address if it is true transfer the fee
    /// @param _collection address of the nft contract
    /// @param _feeNGOPercent fee percentage
    function transferOng(address _collection, uint256 _feeNGOPercent) internal {
        bytes memory _data = abi.encodeWithSignature("ngoAddress()");

        (bool success, ) = address(_collection).call(_data);
        if (success) {
            address _ngo = INft(address(_collection)).ngoAddress();

            if (_ngo != address(0)) {
                (bool success5, ) = _ngo.call{value: _feeNGOPercent}("");
                require(success5, "Send Matic to NGO failed");
                //console.log("Fee que le llega al NGO: ", _feeNGOPercent);
            }
        }
    }

    /// @notice function to chance the item price
    /// @dev receives the item id and the new item price.
    /// @param _itemId: nft id
    /// @param _price: new price

    function changeItemPrice(uint256 _itemId, uint256 _price)
        external
        onlyItemSeller(_itemId)
        greaterThan0(_price)
        nonReentrant
    {
        Item storage item = itemsPerNftId[_itemId];
        item.price = _price;

        emit PriceChanged(_itemId, _price);
    }

    /// @notice change the state of an item
    /// @dev receives the item id and then change the status.
    /// @param _itemId: nft id

    function changeItemStateByIndex(uint256 _itemId)
        external
        onlyItemSeller(_itemId)
        nonReentrant
    {
        Item storage item = itemsPerNftId[_itemId];
        require(!item.sold, "Item sold");
        item.active = !item.active;
        //statusitem
        emit StatusItem(
            item.itemId,
            address(item.nftContract),
            item.tokenId,
            item.seller,
            item.active
        );
    }

    /// @notice set the fee percentage to the mapping 'collectionInfo'
    /// @dev receives the new fee percentage and then mapped with the address
    /// @param _collection: address of the erc721 collection
    /// @param _feePercent: the fee percentage

    function setCollectionInfo(address _collection, uint256 _feePercent)
        public
        onlyNftAdmin
        nonReentrant
    {
        require(
            _feePercent <= 10000,
            "Porcentaje de fee para la coleccion invalido"
        );
        CollectionStruct storage _contractInfo = collectionInfo[
            address(_collection)
        ];

        _contractInfo.feePercentaje = _feePercent;
        _contractInfo.collectionAddress = _collection;

        bool found = false;
        for (uint256 i = 0; i < collectionAddressArray.length; i++) {
            if (collectionAddressArray[i] == _collection) {
                found = true;
            }
        }

        if (!found) {
            collectionAddressArray.push(_collection);
            _contractInfo.active = true;

            if (!INft(address(_collection)).perceptionCollection()) {
                rolesContract.grantRole(
                    rolesContract.getHashRole("COLLECTIONS_ALLOWED"),
                    _collection
                );
            }
        }
    }

    //El index se debe enviar desde el front
    //Esta funcion se encarga
    function deleteCollectionInfo(uint256 _index)
        public
        onlyNftAdmin
        nonReentrant
    {
        address _collection = collectionAddressArray[_index];
        //struct
        CollectionStruct storage _contractInfo = collectionInfo[
            address(_collection)
        ];
        require(_contractInfo.active == true, "The collection is not active");
        _contractInfo.active = false;

        //array
        collectionAddressArray[_index] = collectionAddressArray[
            collectionAddressArray.length - 1
        ];
        collectionAddressArray.pop();
        emit DeleteCollection(_collection);
    }

    /// @notice Change the state of the collection
    /// @dev Sets a collection active or inactive for the use in the marketplace
    /// @param _collection address of the collection to change the state
    function changeCollectionState(address _collection)
        public
        onlyNftAdmin
        nonReentrant
    {
        CollectionStruct storage _contractInfo = collectionInfo[
            address(_collection)
        ];
        _contractInfo.active = !_contractInfo.active;
    }

    /// @notice set the marketplace fee account
    /// @dev receive and address and then set the marketplace fee account
    /// @param _feeAccount: address

    function setfeeAccount(address _feeAccount)
        public
        onlyDefaultAdmin
        nonReentrant
    {
        feeAccount = payable(_feeAccount);
    }

    /// @notice set the address of roles contract
    /// @dev receive an address of the roles contract
    /// @param _rolesContracts: roles contract address

    function setRolesContract(address _rolesContracts)
        public
        onlyDefaultAdmin
        nonReentrant
    {
        rolesContract = IRoles(_rolesContracts);
    }

    /// @notice change the allowance of  nft contracts collection

    function changeContratsAllowed() public onlyDefaultAdmin nonReentrant {
        allContratsAllowed = !allContratsAllowed;
    }

    /// @notice function to return an fee of a collection allowed in the marketplace
    /// @dev receive an address and then return the fee amount of that collection
    /// @return Return the fee of the collection

    function getCollectionInfo(address _collection)
        external
        view
        returns (CollectionStruct memory)
    {
        return collectionInfo[_collection];
    }

    /// @notice function to return an array of a collections allowed in the marketplace
    /// @dev array of the collections allowed
    /// @return Return the array of the collection allowed in the marketplace

    function getCollectionsArray() external view returns (address[] memory) {
        return collectionAddressArray;
    }

    /// @return the allowance of contracts to operate in marketplace

    function getStatusContratsAllowed() external view returns (bool) {
        return allContratsAllowed;
    }

    /// @notice function to return an array
    /// @dev receive an address and then return the nft amount of that address
    /// @param _address:
    /// @return  nfts created per account

    function getItemsPerAccount(address _address)
        external
        view
        returns (uint256[] memory)
    {
        return itemsPerAccount[_address];
    }

    /// @param _itemId: nft id
    /// @return the struct of the item
    function getItem(uint256 _itemId) external view returns (Item memory) {
        return itemsPerNftId[_itemId];
    }

    /// @return an array of items
    function getItemArray() external view returns (uint256[] memory) {
        return itemArray;
    }

    /**
     *
     * @dev Set the collector address
     *
     * Requirements:
     *
     * - The caller must have ``role``'s admin role.
     * - The contract must be paused.
     */

    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyDefaultAdmin
        whenPaused
    {}

    /**
     *
     * @dev See {utils/UUPSUpgradeable-upgradeTo}.
     *
     * Requirements:
     *
     * - The caller must have ``role``'s admin role.
     * - The contract must be paused.
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
     * - The contract must be paused.
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

    /**
     *
     * @dev See {security/PausableUpgradeable-_pause}.
     *
     * Requirements:
     *
     * - The caller must have ``role``'s admin role.
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
     *
     */
    function unpause() external whenPaused onlyDefaultAdmin {
        //Debería ser la misma persona la que deploya el contrato de roles y el de misteryBox
        _unpause();
    }


    /// @notice Withdraw founds
    /// @dev transfer ethers to feeAccount(account who receives marketplace fee), call it if the contract has a lot of ethers inside.
    function emergencyWithdrawAll()
        external
        whenNotPaused
        onlyDefaultAdmin
        nonReentrant
    {
        (bool success, ) = feeAccount.call{value: address(this).balance}("");
        require(success, "Transfer failed!");
    }
}