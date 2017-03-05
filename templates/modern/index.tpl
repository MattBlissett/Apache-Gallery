<div>
	<div id="menu">{ $MENU }</div>
	<div id="nav">
		{ $BROWSELINKS }
	</div>
	<div id="directory">
		<div id="files">
{ $FILES }
		</div>

		<script type="text/javascript">
			var availableTracks = [{ $AVAILABLETRACKS }];
		</script>

		<div id="mapcontainer" class="gallerymap">
			<div id="map" class="map"></div>
		</div>

		<div id="dircomment">
			{ $DIRCOMMENT }
		</div>
	</div>
</div>

<script type="text/javascript">
	var hasMap = true;
</script>
