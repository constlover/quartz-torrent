require "quartz_torrent/log.rb"
require "quartz_torrent/trackerclient.rb"
require "quartz_torrent/peermsg.rb"
require "quartz_torrent/reactor.rb"
require "quartz_torrent/util.rb"
require "quartz_torrent/classifiedpeers.rb"
require "quartz_torrent/classifiedpeers.rb"
require "quartz_torrent/peerholder.rb"
require "quartz_torrent/peermanager.rb"
require "quartz_torrent/blockstate.rb"
require "quartz_torrent/filemanager.rb"
require "quartz_torrent/semaphore.rb"
require "quartz_torrent/piecemanagerrequestmetadata.rb"
require "quartz_torrent/metainfopiecestate.rb"
require "quartz_torrent/extension.rb"
require "quartz_torrent/magnet.rb"


module QuartzTorrent
 
  # Extra metadata stored in a PieceManagerRequestMetadata specific to read requests.
  class ReadRequestMetadata
    def initialize(peer, requestMsg)
      @peer = peer
      @requestMsg = requestMsg
    end
    attr_accessor :peer
    attr_accessor :requestMsg
  end

  # Class used by PeerClientHandler to keep track of information associated with a single torrent
  # being downloaded/uploaded.
  class TorrentData
    def initialize(infoHash, info, trackerClient)
      @infoHash = infoHash
      @info = info
      @trackerClient = trackerClient
      @peerManager = PeerManager.new
      @pieceManagerRequestMetadata = {}
      @pieceManagerMetainfoRequestMetadata = {}
      @bytesDownloaded = 0
      @bytesUploaded = 0
      @magnet = nil
      @peers = PeerHolder.new
      @state = :initializing
      @blockState = nil
      @metainfoPieceState = nil
      @metainfoRequestTimer = nil
      @paused = false
    end
    # The torrents Metainfo.Info struct. This is nil if the torrent has no metadata and we need to download it
    # (i.e. a magnet link)
    attr_accessor :info
    # The infoHash of the torrent
    attr_accessor :infoHash
    attr_accessor :trackerClient
    attr_accessor :peers
    # The MagnetURI object, if this torrent was created from a magnet link. Nil for torrents not created from magnets.
    attr_accessor :magnet
    attr_accessor :peerManager
    attr_accessor :blockState
    attr_accessor :pieceManager
    # Metadata associated with outstanding requests to the PieceManager responsible for the pieces of the torrent data.
    attr_accessor :pieceManagerRequestMetadata
    # Metadata associated with outstanding requests to the PieceManager responsible for the pieces of the torrent metainfo.
    attr_accessor :pieceManagerMetainfoRequestMetadata
    attr_accessor :peerChangeListener
    attr_accessor :bytesDownloaded
    attr_accessor :bytesUploaded
    attr_accessor :state
    attr_accessor :metainfoPieceState
    # The timer handle for the timer that requests metainfo pieces. This is used to cancel the 
    # timer when the metadata is completely downloaded.
    attr_accessor :metainfoRequestTimer
    attr_accessor :paused
  end

  # Data about torrents for use by the end user. 
  class TorrentDataDelegate
    # Create a new TorrentDataDelegate. This is meant to only be called internally.
    def initialize(torrentData, peerClientHandler)
      fillFrom(torrentData)
      @torrentData = torrentData
      @peerClientHandler = peerClientHandler
    end

    # Torrent Metainfo.info struct. This is nil if the torrent has no metadata and we haven't downloaded it yet
    # (i.e. a magnet link).
    attr_accessor :info
    attr_accessor :infoHash
    # Recommended display name for this torrent.
    attr_accessor :recommendedName
    attr_reader :downloadRate
    attr_reader :uploadRate
    attr_reader :downloadRateDataOnly
    attr_reader :uploadRateDataOnly
    attr_reader :completedBytes
    attr_reader :peers
    # State of the torrent. This may be one of :downloading_metainfo, :error, :checking_pieces, :running, :downloading_metainfo, or :deleted.
    # The :deleted state indicates that the torrent that this TorrentDataDelegate refers to is no longer being managed by the peer client.
    attr_reader :state
    attr_reader :completePieceBitfield
    # Length of metainfo info in bytes. This is only set when the state is :downloading_metainfo
    attr_reader :metainfoLength
    # How much of the metainfo info we have downloaded in bytes. This is only set when the state is :downloading_metainfo
    attr_reader :metainfoCompletedLength
    attr_reader :paused
  
    # Update the data in this TorrentDataDelegate from the torrentData
    # object that it was created from. TODO: What if that torrentData is now gone?
    def refresh
      @peerClientHandler.updateDelegateTorrentData self
    end

    # Set the fields of this TorrentDataDelegate from the passed torrentData. 
    # This is meant to only be called internally.
    def internalRefresh
      fillFrom(@torrentData)
    end

    private
    def fillFrom(torrentData)
      @infoHash = torrentData.infoHash
      @info = torrentData.info
      @bytesUploaded = torrentData.bytesUploaded
      @bytesDownloaded = torrentData.bytesDownloaded
      @completedBytes = torrentData.blockState.nil? ? 0 : torrentData.blockState.completedLength
      # This should really be a copy:
      @completePieceBitfield = torrentData.blockState.nil? ? nil : torrentData.blockState.completePieceBitfield
      buildPeersList(torrentData)
      @downloadRate = @peers.reduce(0){ |memo, peer| memo + peer.uploadRate }
      @uploadRate = @peers.reduce(0){ |memo, peer| memo + peer.downloadRate }
      @downloadRateDataOnly = @peers.reduce(0){ |memo, peer| memo + peer.uploadRateDataOnly }
      @uploadRateDataOnly = @peers.reduce(0){ |memo, peer| memo + peer.downloadRateDataOnly }
      @state = torrentData.state
      @metainfoLength = nil
      @paused = torrentData.paused
      @metainfoCompletedLength = nil
      if torrentData.metainfoPieceState
        @metainfoLength = torrentData.metainfoPieceState.metainfoLength
        @metainfoCompletedLength = torrentData.metainfoPieceState.metainfoCompletedLength
      end

      if torrentData.info
        @recommendedName = torrentData.info.name
      else
        if torrentData.magnet
          @recommendedName = torrentData.magnet.displayName
        else
          @recommendedName = nil
        end
      end
    end

    def buildPeersList(torrentData)
      @peers = []
      torrentData.peers.all.each do |peer|
        @peers.push peer.clone
      end
    end

  end

  # This class implements a Reactor Handler object. This Handler implements the PeerClient.
  class PeerClientHandler < QuartzTorrent::Handler
    include QuartzTorrent
  
    def initialize(baseDirectory)
      # Hash of TorrentData objects, keyed by torrent infoHash
      @torrentData = {}

      @baseDirectory = baseDirectory

      @logger = LogManager.getLogger("peerclient")

      # Number of peers we ideally want to try and be downloading/uploading with
      @targetActivePeerCount = 50
      @targetUnchokedPeerCount = 4
      @managePeersPeriod = 10 # Defined in bittorrent spec. Only unchoke peers every 10 seconds.
      @requestBlocksPeriod = 1
      @handshakeTimeout = 1
      @requestTimeout = 60
    end

    attr_reader :torrentData

    # Add a new tracker client. This effectively adds a new torrent to download. Returns the TorrentData object for the 
    # new torrent.
    def addTrackerClient(infoHash, info, trackerclient)
      raise "There is already a tracker registered for torrent #{bytesToHex(infoHash)}" if @torrentData.has_key? infoHash
      torrentData = TorrentData.new(infoHash, info, trackerclient)
      @torrentData[infoHash] = torrentData

      # If we already have the metainfo info for this torrent, we can begin checking the pieces. 
      # If we don't have the metainfo info then we need to get the metainfo first.
      if ! info
        info = MetainfoPieceState.downloaded(@baseDirectory, torrentData.infoHash)
        torrentData.info = info
      end

      if info
        torrentData.pieceManager = QuartzTorrent::PieceManager.new(@baseDirectory, info)

        startCheckingPieces torrentData
      else
        # Request the metainfo from peers.
        torrentData.state = :downloading_metainfo

        @logger.info "Downloading metainfo"
        #torrentData.metainfoPieceState = MetainfoPieceState.new(@baseDirectory, infoHash, )

        # Schedule peer connection management. Recurring and immediate 
        @reactor.scheduleTimer(@managePeersPeriod, [:manage_peers, torrentData.infoHash], true, true)

        # Schedule a timer for requesting metadata pieces from peers.
        t = @reactor.scheduleTimer(@requestBlocksPeriod, [:request_metadata_pieces, infoHash], true, false)
        torrentData.metainfoRequestTimer = t

        # Schedule checking for metainfo PieceManager results (including when piece reading completes)
        @reactor.scheduleTimer(@requestBlocksPeriod, [:check_metadata_piece_manager, infoHash], true, false)
      end
      
      torrentData
    end

    # Remove a torrent.
    def removeTorrent(infoHash)
      torrentData = @torrentData.delete infoHash
  
      if torrentData    
        torrentData.trackerClient.removePeersChangedListener(torrentData.peerChangeListener)
      end

      # Delete all peers related to this torrent
      # Can't do this right now, since it could be in use by an event handler. Use an immediate, non-recurring timer instead.
      @reactor.scheduleTimer(0, [:removetorrent, infoHash], false, true)
    end

    # Pause or unpause the specified torrent.
    def setPaused(infoHash, value)
      torrentData = @torrentData[infoHash]
      if ! torrentData
        @logger.warn "Asked to pause a non-existent torrent #{bytesToHex(infoHash)}"
        return
      end

      return if torrentData.paused == value

      if value
        torrentData.paused = true

        # Disconnect from all peers so we won't reply to any messages.
        torrentData.peers.all.each do |peer|
          if peer.state != :disconnected
            # Close socket 
            withPeersIo(peer, "when removing torrent") do |io|
              setPeerDisconnected(peer)
              close(io)
            end
          end
          torrentData.peers.delete peer
        end 
      else
        torrentData.paused = false
  
        # Get our list of peers and start connecting right away
        # Non-recurring and immediate timer
        @reactor.scheduleTimer(@managePeersPeriod, [:manage_peers, torrentData.infoHash], false, true)
      end


    end

    # Reactor method called when a peer has connected to us.
    def serverInit(metadata, addr, port)
      # A peer connected to us
      # Read handshake message
      @logger.warn "Peer connection from #{addr}:#{port}"
      begin
        msg = PeerHandshake.unserializeExceptPeerIdFrom currentIo
      rescue
        @logger.warn "Peer failed handshake: #{$!}"
        close
        return
      end

      torrentData = torrentDataForHandshake(msg, "#{addr}:#{port}")
      # Are we tracking this torrent?
      if !torrentData
        @logger.warn "Peer sent handshake for unknown torrent"
        close
        return 
      end
      trackerclient = torrentData.trackerClient

      # If we already have too many connections, don't allow this connection.
      classifiedPeers = ClassifiedPeers.new torrentData.peers.all
      if classifiedPeers.establishedPeers.length > @targetActivePeerCount
        @logger.warn "Closing connection to peer from #{addr}:#{port} because we already have #{classifiedPeers.establishedPeers.length} active peers which is > the target count of #{@targetActivePeerCount} "
        close
        return 
      end  

      # Send handshake
      outgoing = PeerHandshake.new
      outgoing.peerId = trackerclient.peerId
      outgoing.infoHash = torrentData.infoHash
      outgoing.serializeTo currentIo

      # Send extended handshake if the peer supports extensions
      if (msg.reserved.unpack("C8")[5] & 0x10) != 0
        @logger.warn "Peer supports extensions. Sending extended handshake"
        extended = Extension.createExtendedHandshake torrentData.info
        extended.serializeTo currentIo
      end
 
      # Read incoming handshake's peerid
      msg.peerId = currentIo.read(PeerHandshake::PeerIdLen)

      if msg.peerId == trackerclient.peerId
        @logger.info "We got a connection from ourself. Closing connection."
        close
        return
      end
     
      peer = nil
      peers = torrentData.peers.findById(msg.peerId)
      if peers
        peers.each do |existingPeer|
          if existingPeer.state != :disconnected
            @logger.warn "Peer with id #{msg.peerId} created a new connection when we already have a connection in state #{existingPeer.state}. Closing new connection."
            close
            return
          else
            if existingPeer.trackerPeer.ip == addr && existingPeer.trackerPeer.port == port
              peer = existingPeer
            end
          end
        end
      end

      if ! peer
        peer = Peer.new(TrackerPeer.new(addr, port))
        updatePeerWithHandshakeInfo(torrentData, msg, peer)
        torrentData.peers.add peer
        if ! peers
          @logger.warn "Unknown peer with id #{msg.peerId} connected."
        else
          @logger.warn "Known peer with id #{msg.peerId} connected from new location."
        end
      else
        @logger.warn "Known peer with id #{msg.peerId} connected from known location."
      end

      @logger.info "Peer #{peer} connected to us. "

      peer.state = :established
      peer.amChoked = true
      peer.peerChoked = true
      peer.amInterested = false
      peer.peerInterested = false
      if torrentData.info
        peer.bitfield = Bitfield.new(torrentData.info.pieces.length)
      else
        peer.bitfield = EmptyBitfield.new
        @logger.info "We have no metainfo yet, so setting peer #{peer} to have an EmptyBitfield"
      end

      # Send bitfield
      sendBitfield(currentIo, torrentData.blockState.completePieceBitfield) if torrentData.blockState

      setMetaInfo(peer)
    end

    # Reactor method called when we have connected to a peer.
    def clientInit(peer)
      # We connected to a peer
      # Send handshake
      torrentData = @torrentData[peer.infoHash]
      if ! torrentData
        @logger.warn "No tracker client found for peer #{peer}. Closing connection."
        close
        return
      end
      trackerclient = torrentData.trackerClient

      @logger.info "Connected to peer #{peer}. Sending handshake."
      msg = PeerHandshake.new
      msg.peerId = trackerclient.peerId
      msg.infoHash = peer.infoHash
      msg.serializeTo currentIo
      peer.state = :handshaking
      @reactor.scheduleTimer(@handshakeTimeout, [:handshake_timeout, peer], false)
      @logger.info "Done sending handshake."

      # Send bitfield
      sendBitfield(currentIo, torrentData.blockState.completePieceBitfield) if torrentData.blockState
    end

    # Reactor method called when there is data ready to be read from a socket
    def recvData(peer)
      msg = nil

      @logger.debug "Got data from peer #{peer}"

      if peer.state == :handshaking
        # Read handshake message
        begin
          @logger.debug "Reading handshake from #{peer}"
          msg = PeerHandshake.unserializeFrom currentIo
        rescue
          @logger.warn "Peer #{peer} failed handshake: #{$!}"
          setPeerDisconnected(peer)
          close
          return
        end
      else
        begin
          @logger.debug "Reading wire-message from #{peer}"
          msg = peer.peerMsgSerializer.unserializeFrom currentIo
          #msg = PeerWireMessage.unserializeFrom currentIo
        rescue EOFError
          @logger.info "Peer #{peer} disconnected."
          setPeerDisconnected(peer)
          close
          return
        rescue
          @logger.warn "Unserializing message from peer #{peer} failed: #{$!}"
          @logger.warn $!.backtrace.join "\n"
          setPeerDisconnected(peer)
          close
          return
        end
        peer.updateUploadRate msg
        @logger.debug "Peer #{peer} upload rate: #{peer.uploadRate.value}  data only: #{peer.uploadRateDataOnly.value}"
      end


      if msg.is_a? PeerHandshake
        # This is a remote peer that we connected to returning our handshake.
        processHandshake(msg, peer)
        peer.state = :established
        peer.amChoked = true
        peer.peerChoked = true
        peer.amInterested = false
        peer.peerInterested = false
      elsif msg.is_a? BitfieldMessage
        @logger.warn "Received bitfield message from peer."
        handleBitfield(msg, peer)
      elsif msg.is_a? Unchoke
        @logger.warn "Received unchoke message from peer."
        peer.amChoked = false
      elsif msg.is_a? Choke
        @logger.warn "Received choke message from peer."
        peer.amChoked = true
      elsif msg.is_a? Interested
        @logger.warn "Received interested message from peer."
        peer.peerInterested = true
      elsif msg.is_a? Uninterested
        @logger.warn "Received uninterested message from peer."
        peer.peerInterested = false
      elsif msg.is_a? Piece
        @logger.warn "Received piece message from peer for torrent #{bytesToHex(peer.infoHash)}: piece #{msg.pieceIndex} offset #{msg.blockOffset} length #{msg.data.length}."
        handlePieceReceive(msg, peer)
      elsif msg.is_a? Request
        @logger.warn "Received request message from peer for torrent #{bytesToHex(peer.infoHash)}: piece #{msg.pieceIndex} offset #{msg.blockOffset} length #{msg.blockLength}."
        handleRequest(msg, peer)
      elsif msg.is_a? Have
        @logger.warn "Received have message from peer for torrent #{bytesToHex(peer.infoHash)}: piece #{msg.pieceIndex}"
        handleHave(msg, peer)
      elsif msg.is_a? KeepAlive
        @logger.warn "Received keep alive message from peer."
      elsif msg.is_a? ExtendedHandshake
        @logger.warn "Received extended handshake message from peer."
        handleExtendedHandshake(msg, peer)
      elsif msg.is_a? ExtendedMetaInfo
        @logger.warn "Received extended metainfo message from peer."
        handleExtendedMetainfo(msg, peer)
      else
        @logger.warn "Received a #{msg.class} message but handler is not implemented"
      end
    end

    # Reactor method called when a scheduled timer expires.
    def timerExpired(metadata)
      if metadata.is_a?(Array) && metadata[0] == :manage_peers
        @logger.info "Managing peers for torrent #{bytesToHex(metadata[1])}"
        managePeers(metadata[1])
      elsif metadata.is_a?(Array) && metadata[0] == :request_blocks
        #@logger.info "Requesting blocks for torrent #{bytesToHex(metadata[1])}"
        requestBlocks(metadata[1])
      elsif metadata.is_a?(Array) && metadata[0] == :check_piece_manager
        #@logger.info "Checking for PieceManager results"
        checkPieceManagerResults(metadata[1])
      elsif metadata.is_a?(Array) && metadata[0] == :handshake_timeout
        handleHandshakeTimeout(metadata[1])
      elsif metadata.is_a?(Array) && metadata[0] == :removetorrent
        torrentData = @torrentData[metadata[1]]
        if ! torrentData
          @logger.warn "No torrent data found for torrent #{bytesToHex(metadata[1])}."
          return
        end

        # Remove all the peers for this torrent.
        torrentData.peers.all.each do |peer|
          if peer.state != :disconnected
            # Close socket 
            withPeersIo(peer, "when removing torrent") do |io|
              setPeerDisconnected(peer)
              close(io)
            end
          end
          torrentData.peers.delete peer
        end
      elsif metadata.is_a?(Array) && metadata[0] == :get_torrent_data
        @torrentData.each do |k,v|
          begin
            if metadata[3].nil? || k == metadata[3]
              v = TorrentDataDelegate.new(v, self)
              metadata[1][k] = v
            end
          rescue
            @logger.error "Error building torrent data response for user: #{$!}"
            @logger.error "#{$!.backtrace.join("\n")}"
          end
        end
        metadata[2].signal
      elsif metadata.is_a?(Array) && metadata[0] == :update_torrent_data
        delegate = metadata[1]
        if ! @torrentData.has_key?(infoHash)
          delegate.state = :deleted 
        else
          delegate.internalRefresh
        end
        metadata[2].signal
      elsif metadata.is_a?(Array) && metadata[0] == :request_metadata_pieces
        requestMetadataPieces(metadata[1])
      elsif metadata.is_a?(Array) && metadata[0] == :check_metadata_piece_manager
        checkMetadataPieceManagerResults(metadata[1])
      else
        @logger.info "Unknown timer #{metadata} expired."
      end
    end

    # Reactor method called when an IO error occurs.
    def error(peer, details)
      # If a peer closes the connection during handshake before we determine their id, we don't have a completed
      # Peer object yet. In this case the peer parameter is the symbol :listener_socket
      if peer == :listener_socket
        @logger.info "Error with handshaking peer: #{details}. Closing connection."
      else
        @logger.info "Error with peer #{peer}: #{details}. Closing connection."
        setPeerDisconnected(peer)
      end
      # Close connection
      close
    end
    
    # Get a hash of new TorrentDataDelegate objects keyed by torrent infohash.
    # This method is meant to be called from a different thread than the one
    # the reactor is running in. This method is not immediate but blocks until the
    # data is prepared. 
    # If infoHash is passed, only that torrent data is returned (still in a hashtable; just one entry)
    def getDelegateTorrentData(infoHash = nil)
      # Use an immediate, non-recurring timer.
      result = {}
      return result if stopped?
      semaphore = Semaphore.new
      @reactor.scheduleTimer(0, [:get_torrent_data, result, semaphore, infoHash], false, true)
      semaphore.wait
      result
    end

    def updateDelegateTorrentData(delegate)
      return if stopped?
      # Use an immediate, non-recurring timer.
      semaphore = Semaphore.new
      @reactor.scheduleTimer(0, [:update_torrent_data, delegate, semaphore], false, true)
      semaphore.wait
      result
    end

    private
    def setPeerDisconnected(peer)
      peer.state = :disconnected

      torrentData = @torrentData[peer.infoHash]
      # Are we tracking this torrent?
      if torrentData && torrentData.blockState
        # For any outstanding requests, mark that we no longer have requested them
        peer.requestedBlocks.each do |blockIndex, b|
          blockInfo = torrentData.blockState.createBlockinfoByBlockIndex(blockIndex)
          torrentData.blockState.setBlockRequested blockInfo, false
        end
        peer.requestedBlocks.clear
      end

    end

    def processHandshake(msg, peer)
      torrentData = torrentDataForHandshake(msg, peer)
      # Are we tracking this torrent?
      return false if !torrentData

      if msg.peerId == torrentData.trackerClient.peerId
        @logger.info "We connected to ourself. Closing connection."
        peer.isUs = true
        close
        return
      end

      peers = torrentData.peers.findById(msg.peerId)
      if peers
        peers.each do |existingPeer|
          if existingPeer.state == :connected
            @logger.warn "Peer with id #{msg.peerId} created a new connection when we already have a connection in state #{existingPeer.state}. Closing new connection."
            torrentData.peers.delete existingPeer
            setPeerDisconnected(peer)
            close
            return
          end
        end
      end

      trackerclient = torrentData.trackerClient

      updatePeerWithHandshakeInfo(torrentData, msg, peer)
      if torrentData.info
        peer.bitfield = Bitfield.new(torrentData.info.pieces.length)
      else
        peer.bitfield = EmptyBitfield.new
        @logger.info "We have no metainfo yet, so setting peer #{peer} to have an EmptyBitfield"
      end

      # Send extended handshake if the peer supports extensions
      if (msg.reserved.unpack("C8")[5] & 0x10) != 0
        @logger.warn "Peer supports extensions. Sending extended handshake"
        extended = Extension.createExtendedHandshake torrentData.info
        extended.serializeTo currentIo
      end

      true
    end

    def torrentDataForHandshake(msg, peer)
      torrentData = @torrentData[msg.infoHash]
      # Are we tracking this torrent?
      if !torrentData
        if peer.is_a?(Peer)
          @logger.info "Peer #{peer} failed handshake: we are not managing torrent #{bytesToHex(msg.infoHash)}"
          setPeerDisconnected(peer)
        else
          @logger.info "Incoming peer #{peer} failed handshake: we are not managing torrent #{bytesToHex(msg.infoHash)}"
        end
        close
        return nil
      end
      torrentData
    end

    def updatePeerWithHandshakeInfo(torrentData, msg, peer)
      @logger.info "peer #{peer} sent valid handshake for torrent #{bytesToHex(torrentData.infoHash)}"
      peer.infoHash = msg.infoHash
      # If this was a peer we got from a tracker that had no id then we only learn the id on handshake.
      peer.trackerPeer.id = msg.peerId
      torrentData.peers.idSet peer
    end

    def handleHandshakeTimeout(peer)
      if peer.state == :handshaking
        @logger.warn "Peer #{peer} failed handshake: handshake timed out after #{@handshakeTimeout} seconds."
        withPeersIo(peer, "handling handshake timeout") do |io|
          setPeerDisconnected(peer)
          close(io)
        end
      end
    end

    def managePeers(infoHash)
      torrentData = @torrentData[infoHash]
      if ! torrentData
        @logger.error "Manage peers: tracker client for torrent #{bytesToHex(infoHash)} not found."
        return
      end

      return if torrentData.paused

      trackerclient = torrentData.trackerClient

      # Update our internal peer list for this torrent from the tracker client
      trackerclient.peers.each do |p| 
        # Don't treat ourself as a peer.
        next if p.id && p.id == trackerclient.peerId

        if ! torrentData.peers.findByAddr(p.ip, p.port)
          @logger.debug "Adding tracker peer #{p} to peers list"
          peer = Peer.new(p)
          peer.infoHash = infoHash
          torrentData.peers.add peer
        end
      end

      classifiedPeers = ClassifiedPeers.new torrentData.peers.all

      manager = torrentData.peerManager
      if ! manager
        @logger.error "Manage peers: peer manager client for torrent #{bytesToHex(infoHash)} not found."
        return
      end

      toConnect = manager.manageConnections(classifiedPeers)
      toConnect.each do |peer|
        @logger.info "Connecting to peer #{peer}"
        connect peer.trackerPeer.ip, peer.trackerPeer.port, peer
      end

      manageResult = manager.managePeers(classifiedPeers)
      manageResult.unchoke.each do |peer|
        @logger.info "Unchoking peer #{peer}"
        withPeersIo(peer, "unchoking peer") do |io|
          msg = Unchoke.new
          sendMessageToPeer msg, io, peer
          peer.peerChoked = false
        end
      end

      manageResult.choke.each do |peer|
        @logger.info "Choking peer #{peer}"
        withPeersIo(peer, "choking peer") do |io|
          msg = Choke.new
          sendMessageToPeer msg, io, peer
          peer.peerChoked = true
        end
      end

    end

    def requestBlocks(infoHash)
      torrentData = @torrentData[infoHash]
      if ! torrentData
        @logger.error "Request blocks peers: tracker client for torrent #{bytesToHex(infoHash)} not found."
        return
      end

      return if torrentData.paused

      classifiedPeers = ClassifiedPeers.new torrentData.peers.all

      if ! torrentData.blockState
        @logger.error "Request blocks peers: no blockstate yet."
        return
      end

      # Delete any timed-out requests.
      classifiedPeers.establishedPeers.each do |peer|
        toDelete = []
        peer.requestedBlocks.each do |blockIndex, requestTime|
          toDelete.push blockIndex if (Time.new - requestTime) > @requestTimeout
        end
        toDelete.each do |blockIndex|
          @logger.info "Block #{blockIndex} request timed out."
          blockInfo = torrentData.blockState.createBlockinfoByBlockIndex(blockIndex)
          torrentData.blockState.setBlockRequested blockInfo, false
          peer.requestedBlocks.delete blockIndex
        end
      end

      # Update the allowed pending requests based on how well the peer did since last time.
      classifiedPeers.establishedPeers.each do |peer|
        if peer.requestedBlocksSizeLastPass
          if peer.requestedBlocksSizeLastPass == peer.maxRequestedBlocks
            downloaded = peer.requestedBlocksSizeLastPass - peer.requestedBlocks.size
            if downloaded > peer.maxRequestedBlocks*8/10
              peer.maxRequestedBlocks = peer.maxRequestedBlocks * 12 / 10
            elsif downloaded == 0
              peer.maxRequestedBlocks = peer.maxRequestedBlocks * 8 / 10
            end
            peer.maxRequestedBlocks = 10 if peer.maxRequestedBlocks < 10
          end
        end
      end

      # Request blocks
      blockInfos = torrentData.blockState.findRequestableBlocks(classifiedPeers, 100)
      blockInfos.each do |blockInfo|
        # Pick one of the peers that has the piece to download it from. Pick one of the
        # peers with the top 3 upload rates.
        elegiblePeers = blockInfo.peers.find_all{ |p| p.requestedBlocks.length < p.maxRequestedBlocks }.sort{ |a,b| b.uploadRate.value <=> a.uploadRate.value}
        random = elegiblePeers[rand(blockInfo.peers.size)]
        peer = elegiblePeers.first(3).push(random).shuffle.first
        next if ! peer
        withPeersIo(peer, "requesting block") do |io|
          if ! peer.amInterested
            # Let this peer know that I'm interested if I haven't yet.
            msg = Interested.new
            sendMessageToPeer msg, io, peer
            peer.amInterested = true
          end
          @logger.info "Requesting block from #{peer}: piece #{blockInfo.pieceIndex} offset #{blockInfo.offset} length #{blockInfo.length}"
          msg = blockInfo.getRequest
          sendMessageToPeer msg, io, peer
          torrentData.blockState.setBlockRequested blockInfo, true
          peer.requestedBlocks[blockInfo.blockIndex] = Time.new
        end
      end

      classifiedPeers.establishedPeers.each { |peer| peer.requestedBlocksSizeLastPass = peer.requestedBlocks.length }
    end

    # For a torrent where we don't have the metainfo, request metainfo pieces from peers.
    def requestMetadataPieces(infoHash)
      torrentData = @torrentData[infoHash]
      if ! torrentData
        @logger.error "Request metadata pices: torrent data for torrent #{bytesToHex(infoHash)} not found."
        return
      end
      
      return if torrentData.paused

      # We may not have completed the extended handshake with the peer which specifies the torrent size.
      # In this case torrentData.metainfoPieceState is not yet set.
      return if ! torrentData.metainfoPieceState

      @logger.info "Obtained all pieces of metainfo." if torrentData.metainfoPieceState.complete?

      pieces = torrentData.metainfoPieceState.findRequestablePieces
      classifiedPeers = ClassifiedPeers.new torrentData.peers.all
      peers = torrentData.metainfoPieceState.findRequestablePeers(classifiedPeers)
  
      if peers.size > 0
        # For now, just request all pieces from the first peer.
        pieces.each do |pieceIndex|
          msg = ExtendedMetaInfo.new
          msg.msgType = :request
          msg.piece = pieceIndex
          withPeersIo(peers.first, "requesting metadata piece") do |io|
            sendMessageToPeer msg, io, peers.first
            torrentData.metainfoPieceState.setPieceRequested(pieceIndex, true)
            @logger.info "Requesting metainfo piece from #{peers.first}: piece #{pieceIndex}"
          end
        end
      else
        @logger.error "No peers found that have metadata."
      end

    end

    def checkMetadataPieceManagerResults(infoHash)
      torrentData = @torrentData[infoHash]
      if ! torrentData
        @logger.error "Request blocks peers: tracker client for torrent #{bytesToHex(infoHash)} not found."
        return
      end
 
      # We may not have completed the extended handshake with the peer which specifies the torrent size.
      # In this case torrentData.metainfoPieceState is not yet set.
      return if ! torrentData.metainfoPieceState

      results = torrentData.metainfoPieceState.checkResults
      results.each do |result|
        metaData = torrentData.pieceManagerMetainfoRequestMetadata.delete(result.requestId)
        if ! metaData
          @logger.error "Can't find metadata for PieceManager request #{result.requestId}"
          next
        end

        if metaData.type == :read && result.successful?
          # Send the piece to the peer.
          msg = ExtendedMetaInfo.new
          msg.msgType = :piece
          msg.piece = metaData.data.requestMsg.piece
          msg.data = result.data
          withPeersIo(metaData.data.peer, "sending extended metainfo piece message") do |io|
            @logger.info "Sending metainfo piece to #{metaData.data.peer}: piece #{msg.piece}"
            sendMessageToPeer msg, io, metaData.data.peer
          end
          result.data
        end
      end

      if torrentData.metainfoPieceState.complete? && torrentData.state == :downloading_metainfo
        @logger.info "Obtained all pieces of metainfo. Will begin checking existing pieces."
        torrentData.metainfoPieceState.flush
        # We don't need to download metainfo anymore.
        cancelTimer torrentData.metainfoRequestTimer if torrentData.metainfoRequestTimer
        info = MetainfoPieceState.downloaded(@baseDirectory, torrentData.infoHash)
        if info
          torrentData.info = info
          torrentData.pieceManager = QuartzTorrent::PieceManager.new(@baseDirectory, info)
          startCheckingPieces torrentData
        else
          @logger.error "Metadata download is complete but reading the metadata failed"
          torrentData.state = :error
        end
      end
    end

    def handlePieceReceive(msg, peer)
      torrentData = @torrentData[peer.infoHash]
      if ! torrentData
        @logger.error "Receive piece: torrent data for torrent #{bytesToHex(peer.infoHash)} not found."
        return
      end

      if ! torrentData.blockState
        @logger.error "Receive piece: no blockstate yet."
        return
      end

      blockInfo = torrentData.blockState.createBlockinfoByPieceResponse(msg.pieceIndex, msg.blockOffset, msg.data.length)
      if torrentData.blockState.blockCompleted?(blockInfo)
        @logger.info "Receive piece: we already have this block. Ignoring this message."
        return
      end
      peer.requestedBlocks.delete blockInfo.blockIndex
      # Block is marked as not requested when hash is confirmed

      torrentData.bytesDownloaded += msg.data.length
      id = torrentData.pieceManager.writeBlock(msg.pieceIndex, msg.blockOffset, msg.data)
      torrentData.pieceManagerRequestMetadata[id] = PieceManagerRequestMetadata.new(:write, msg)
    end

    def handleRequest(msg, peer)
      if peer.peerChoked
        @logger.warn "Request piece: peer #{peer} requested a block when they are choked."
        return
      end

      torrentData = @torrentData[peer.infoHash]
      if ! torrentData
        @logger.error "Request piece: torrent data for torrent #{bytesToHex(peer.infoHash)} not found."
        return
      end
      if msg.blockLength <= 0
        @logger.error "Request piece: peer requested block of length #{msg.blockLength} which is invalid."
        return
      end

      id = torrentData.pieceManager.readBlock(msg.pieceIndex, msg.blockOffset, msg.blockLength)
      torrentData.pieceManagerRequestMetadata[id] = PieceManagerRequestMetadata.new(:read, ReadRequestMetadata.new(peer,msg))
    end

    def handleBitfield(msg, peer)
      torrentData = @torrentData[peer.infoHash]
      if ! torrentData
        @logger.error "Bitfield: torrent data for torrent #{bytesToHex(peer.infoHash)} not found."
        return
      end

      peer.bitfield = msg.bitfield

      if ! torrentData.blockState
        @logger.warn "Bitfield: no blockstate yet."
        return
      end

      # If we are interested in something from this peer, let them know.
      needed = torrentData.blockState.completePieceBitfield.compliment
      needed.intersection!(peer.bitfield)
      if ! needed.allClear?
        if ! peer.amInterested
          @logger.info "Need some pieces from peer #{peer} so sending Interested message"
          msg = Interested.new
          sendMessageToPeer msg, currentIo, peer
          peer.amInterested = true
        end
      end
    end

    def handleHave(msg, peer)
      torrentData = @torrentData[peer.infoHash]
      if ! torrentData
        @logger.error "Have: torrent data for torrent #{bytesToHex(peer.infoHash)} not found."
        return
      end

      if msg.pieceIndex >= peer.bitfield.length
        @logger.warn "Peer #{peer} sent Have message with invalid piece index"
        return
      end

      # Update peer's bitfield
      peer.bitfield.set msg.pieceIndex

      if ! torrentData.blockState
        @logger.warn "Have: no blockstate yet."
        return
      end

      # If we are interested in something from this peer, let them know.
      if ! torrentData.blockState.completePieceBitfield.set?(msg.pieceIndex)
        @logger.info "Peer #{peer} just got a piece we need so sending Interested message"
        msg = Interested.new
        sendMessageToPeer msg, currentIo, peer
        peer.amInterested = true
      end
    end

    def checkPieceManagerResults(infoHash)
      torrentData = @torrentData[infoHash]
      if ! torrentData
        @logger.error "Request blocks peers: tracker client for torrent #{bytesToHex(infoHash)} not found."
        return
      end
 
      while true
        result = torrentData.pieceManager.nextResult
        break if ! result
        metaData = torrentData.pieceManagerRequestMetadata.delete(result.requestId)
        if ! metaData
          @logger.error "Can't find metadata for PieceManager request #{result.requestId}"
          next
        end
      
        if metaData.type == :write
          if result.successful?
            @logger.info "Block written to disk. "
            # Block successfully written!
            torrentData.blockState.setBlockCompleted metaData.data.pieceIndex, metaData.data.blockOffset, true do |pieceIndex|
              # The peice is completed! Check hash.
              @logger.info "Piece #{pieceIndex} is complete. Checking hash. "
              id = torrentData.pieceManager.checkPieceHash(metaData.data.pieceIndex)
              torrentData.pieceManagerRequestMetadata[id] = PieceManagerRequestMetadata.new(:hash, metaData.data.pieceIndex)
            end
          else
            # Block failed! Clear completed and requested state.
            torrentData.blockState.setBlockCompleted metaData.data.pieceIndex, metaData.data.blockOffset, false
            @logger.error "Writing block failed: #{result.error}"
          end
        elsif metaData.type == :read
          if result.successful?
            readRequestMetadata = metaData.data
            peer = readRequestMetadata.peer
            withPeersIo(peer, "sending piece message") do |io|
              msg = Piece.new
              msg.pieceIndex = readRequestMetadata.requestMsg.pieceIndex
              msg.blockOffset = readRequestMetadata.requestMsg.blockOffset
              msg.data = result.data
              sendMessageToPeer msg, io, peer
              torrentData.bytesUploaded += msg.data.length
              @logger.info "Sending piece to peer"
            end
          else
            @logger.error "Reading block failed: #{result.error}"
          end
        elsif metaData.type == :hash
          if result.successful?
            @logger.info "Hash of piece #{metaData.data} is correct"
            sendHaves(torrentData, metaData.data)
            sendUninterested(torrentData)
          else
            @logger.info "Hash of piece #{metaData.data} is incorrect. Marking piece as not complete."
            torrentData.blockState.setPieceCompleted metaData.data, false
          end
        elsif metaData.type == :check_existing
          handleCheckExistingResult(torrentData, result)
        end
      end
    end

    # Handle the result of the PieceManager's checkExisting (check which pieces we already have) operation.
    # If the resukt is successful, this begins the actual download.
    def handleCheckExistingResult(torrentData, pieceManagerResult)
      if pieceManagerResult.successful?
        existingBitfield = pieceManagerResult.data
        @logger.info "We already have #{existingBitfield.countSet}/#{existingBitfield.length} pieces." 

        info = torrentData.info
       
        torrentData.blockState = BlockState.new(info, existingBitfield)

        @logger.info "Starting torrent #{bytesToHex(torrentData.infoHash)}. Information:"
        @logger.info "  piece length:     #{info.pieceLen}"
        @logger.info "  number of pieces: #{info.pieces.size}"
        @logger.info "  total length      #{info.dataLength}"

        startDownload torrentData
      else
        @logger.info "Checking existing pieces of torrent #{bytesToHex(torrentData.infoHash)} failed: #{pieceManagerResult.error}"
        torrentData.state = :error
      end
    end

    # Start checking which pieces we already have downloaded. This method schedules the necessary timers
    # and changes the state to :checking_pieces. When the pieces are finished being checked the actual download will
    # begin.
    # Preconditions: The torrentData object already has it's info member set.
    def startCheckingPieces(torrentData)
      torrentData.pieceManager = QuartzTorrent::PieceManager.new(@baseDirectory, torrentData.info)

      torrentData.state = :checking_pieces
      @logger.info "Checking pieces of torrent #{bytesToHex(torrentData.infoHash)} asynchronously."
      id = torrentData.pieceManager.findExistingPieces
      torrentData.pieceManagerRequestMetadata[id] = PieceManagerRequestMetadata.new(:check_existing, nil)

      if ! torrentData.metainfoPieceState
        torrentData.metainfoPieceState = MetainfoPieceState.new(@baseDirectory, torrentData.infoHash, nil, torrentData.info)
      end

      # Schedule checking for PieceManager results
      @reactor.scheduleTimer(@requestBlocksPeriod, [:check_piece_manager, torrentData.infoHash], true, false)
    end
 
    # Start the actual torrent download. This method schedules the necessary timers and registers the necessary listeners
    # and changes the state to :running. It is meant to be called after checking for existing pieces or downloading the 
    # torrent metadata (if this is a magnet link torrent)
    def startDownload(torrentData)
      # Add a listener for when the tracker's peers change.
      torrentData.peerChangeListener = Proc.new do
        @logger.info "Managing peers for torrent #{bytesToHex(torrentData.infoHash)} on peer change event"
  
        # Non-recurring and immediate timer
        @reactor.scheduleTimer(@managePeersPeriod, [:manage_peers, torrentData.infoHash], false, true)
      end
      torrentData.trackerClient.addPeersChangedListener torrentData.peerChangeListener

      # Schedule peer connection management. Recurring and immediate 
      @reactor.scheduleTimer(@managePeersPeriod, [:manage_peers, torrentData.infoHash], true, true)
      # Schedule requesting blocks from peers. Recurring and not immediate
      @reactor.scheduleTimer(@requestBlocksPeriod, [:request_blocks, torrentData.infoHash], true, false)
      torrentData.state = :running
    end
 
    def handleExtendedHandshake(msg, peer)
      torrentData = @torrentData[peer.infoHash]
      if ! torrentData
        @logger.error "Extended Handshake: torrent data for torrent #{bytesToHex(peer.infoHash)} not found."
        return
      end

      metadataSize = msg.dict['metadata_size']
      if metadataSize
        # This peer knows the size of the metadata. If we haven't created our MetainfoPieceState yet, create it now.
        if ! torrentData.metainfoPieceState
          @logger.info "Extended Handshake: Learned that metadata size is #{metadataSize}. Creating MetainfoPieceState"
          torrentData.metainfoPieceState = MetainfoPieceState.new(@baseDirectory, torrentData.infoHash, metadataSize)
        end
      end

    end

    def handleExtendedMetainfo(msg, peer)
      torrentData = @torrentData[peer.infoHash]
      if ! torrentData
        @logger.error "Extended Handshake: torrent data for torrent #{bytesToHex(peer.infoHash)} not found."
        return
      end

      if msg.msgType == :request
        @logger.info "Got extended metainfo request for piece #{msg.piece}"
        # Build a response for this piece.
        if torrentData.metainfoPieceState.pieceCompleted? msg.piece
          id = torrentData.metainfoPieceState.readPiece msg.piece
          torrentData.pieceManagerMetainfoRequestMetadata[id] = 
            PieceManagerRequestMetadata.new(:read, ReadRequestMetadata.new(peer,msg))
        else
          reject = ExtendedMetaInfo.new
          reject.msgType = :reject
          reject.piece = msg.piece
          withPeersIo(peer, "sending extended metainfo reject message") do |io|
            @logger.info "Sending metainfo reject to #{peer}: piece #{msg.piece}"
            sendMessageToPeer reject, io, peer
          end
        end
      elsif msg.msgType == :piece
        @logger.info "Got extended metainfo piece response for piece #{msg.piece}"
        if ! torrentData.metainfoPieceState.pieceCompleted? msg.piece
          id = torrentData.metainfoPieceState.savePiece msg.piece, msg.data
          torrentData.pieceManagerMetainfoRequestMetadata[id] = 
            PieceManagerRequestMetadata.new(:write, msg)
        end
      elsif msg.msgType == :reject
        @logger.info "Got extended metainfo reject response for piece #{msg.piece}"
        # Mark this peer as bad.
        torrentData.metainfoPieceState.markPeerBad peer
        torrentData.metainfoPieceState.setPieceRequested(msg.piece, false)
      end
    end

    # Find the io associated with the peer and yield it to the passed block.
    # If no io is found an error is logged.
    #
    def withPeersIo(peer, what = nil)
      io = findIoByMetainfo(peer)
      if io
        yield io
      else
        s = ""
        s = "when #{what}" if what
        @logger.warn "Couldn't find the io for peer #{peer} #{what}"
      end
    end

    def sendBitfield(io, bitfield)
      set = bitfield.countSet
      if set > 0
        @logger.info "Sending bitfield with #{set} bits set of size #{bitfield.length}."
        msg = BitfieldMessage.new
        msg.bitfield = bitfield
        msg.serializeTo io
      end
    end

    def sendHaves(torrentData, pieceIndex)
      @logger.info "Sending Have messages to all connected peers for piece #{pieceIndex}"
      torrentData.peers.all.each do |peer|
        next if peer.state != :established
        withPeersIo(peer, "when sending Have message") do |io|
          msg = Have.new
          msg.pieceIndex = pieceIndex
          sendMessageToPeer msg, io, peer
        end
      end
    end

    def sendUninterested(torrentData)
      # If we are no longer interested in peers once this piece has been completed, let them know
      return if ! torrentData.blockState
      needed = torrentData.blockState.completePieceBitfield.compliment
      
      classifiedPeers = ClassifiedPeers.new torrentData.peers.all
      classifiedPeers.establishedPeers.each do |peer|
        # Don't bother sending uninterested message if we are already uninterested.
        next if ! peer.amInterested
        needFromPeer = needed.intersection(peer.bitfield)
        if needFromPeer.allClear?
          withPeersIo(peer, "when sending Uninterested message") do |io|
            msg = Uninterested.new
            sendMessageToPeer msg, io, peer
            peer.amInterested = false
            @logger.info "Sending Uninterested message to peer #{peer}"
          end
        end
      end
    end

    def sendMessageToPeer(msg, io, peer)
      peer.updateDownloadRate(msg)
      begin
        peer.peerMsgSerializer.serializeTo(msg, io)
      rescue
        e = Exception.new "Sending message to peer #{peer} failed: #{$!.message}"
        e.set_backtrace e.backtrace
        raise e
      end
      msg.serializeTo io
    end
  end

  # Represents a client that talks to bittorrent peers. This is the main class used to download and upload
  # bittorrents.
  class PeerClient 

    # Create a new PeerClient that will store torrents udner the specified baseDirectory.
    def initialize(baseDirectory)
      @port = 9998
      @handler = nil
      @stopped = true
      @reactor = nil
      @logger = LogManager.getLogger("peerclient")
      @worker = nil
      @handler = PeerClientHandler.new baseDirectory
      @reactor = QuartzTorrent::Reactor.new(@handler, LogManager.getLogger("peerclient.reactor"))
      @toStart = []
    end

    # Set the port used by the torrent peer client. This only has an effect if start has not yet been called.
    attr_accessor :port

    # Start the PeerClient: open the listening port, and start a new thread to begin downloading/uploading pieces.
    def start 
      return if ! @stopped

      @reactor.listen("0.0.0.0",@port,:listener_socket)

      @stopped = false
      @worker = Thread.new do
        initThread("peerclient")
        @toStart.each{ |trackerclient| trackerclient.start }
        @reactor.start 
        @logger.info "Reactor stopped."
        @handler.torrentData.each do |k,v|
          v.trackerClient.stop
        end 
      end
    end

    # Stop the PeerClient. This method may take some time to complete.
    def stop
      return if @stopped

      @logger.info "Stop called. Stopping reactor"
      @reactor.stop
      if @worker
        @logger.info "Worker wait timed out after 10 seconds. Shutting down anyway" if ! @worker.join(10)
      end
      @stopped = true
    end

    # Add a new torrent to manage described by a Metainfo object. This is generally the 
    # method to call if you have a .torrent file.
    def addTorrentByMetainfo(metainfo)
      raise "addTorrentByMetainfo should be called with a Metainfo object, not #{metainfo.class}" if ! metainfo.is_a?(Metainfo)
      trackerclient = TrackerClient.createFromMetainfo(metainfo, false)
      addTorrent(trackerclient, metainfo.infoHash, metainfo.info)
    end

    # Add a new torrent to manage given an announceUrl and an infoHash. 
    def addTorrentWithoutMetainfo(announceUrl, infoHash, magnet = nil)
      raise "addTorrentWithoutMetainfo should be called with a Magnet object, not a #{magnet.class}" if magnet && ! magnet.is_a?(MagnetURI)
      trackerclient = TrackerClient.create(announceUrl, infoHash, 0, false)
      addTorrent(trackerclient, infoHash, nil, magnet)
    end
  
    # Add a new torrent to manage given a MagnetURI object. This is generally the 
    # method to call if you have a magnet link.
    def addTorrentByMagnetURI(magnet)
      raise "addTorrentByMagnetURI should be called with a MagnetURI object, not a #{magnet.class}" if ! magnet.is_a?(MagnetURI)

      trackerUrl = magnet.tracker
      raise "addTorrentByMagnetURI can't handle magnet links that don't have a tracker URL." if !trackerUrl

      addTorrentWithoutMetainfo(trackerUrl, magnet.btInfoHash, magnet)
    end

    # Get a hash of new TorrentDataDelegate objects keyed by torrent infohash. This is the method to 
    # call to get information about the state of torrents being downloaded.
    def torrentData(infoHash = nil)
      # This will have to work by putting an event in the handler's queue, and blocking for a response.
      # The handler will build a response and return it.
      @handler.getDelegateTorrentData(infoHash)
    end
 
    # Pause or unpause the specified torrent.
    def setPaused(infoHash, value)
      @handler.setPaused(infoHash, value)
    end

    private
    # Helper method for adding a torrent.
    def addTorrent(trackerclient, infoHash, info, magnet = nil)
      trackerclient.port = @port

      torrentData = @handler.addTrackerClient(infoHash, info, trackerclient)
      torrentData.magnet = magnet

      trackerclient.dynamicRequestParamsBuilder = Proc.new do
        torrentData = @handler.torrentData[infoHash]
        dataLength = (info ? info.dataLength : nil)
        result = TrackerDynamicRequestParams.new(dataLength)
        if torrentData && torrentData.blockState
          result.left = torrentData.blockState.totalLength - torrentData.blockState.completedLength
          result.downloaded = torrentData.bytesDownloaded
          result.uploaded = torrentData.bytesUploaded
        end
        result
      end

      # If we haven't started yet then add this trackerclient to a queue of 
      # trackerclients to start once we are started. If we start too soon we 
      # will connect to the tracker, and it will try to connect back to us before we are listening.
      if ! trackerclient.started?
        if @stopped
          @toStart.push trackerclient
        else
          trackerclient.start 
        end
      end
    end   

  end
end
