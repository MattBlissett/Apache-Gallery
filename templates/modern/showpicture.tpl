<div id="page">
	<div id="menu">{ $MENU }</div>

	<div id="directory">
		<div id="picture">
			Viewing picture { $NUMBER } of { $TOTAL } at { $RESOLUTION } pixels<br/>
			<img rel="foaf:primaryTopicOf" src="{ $SRC }" alt="{ $TITLE }"/><br/>
			Size [ { $SIZES } ]<br/>
			Slideshow [ { $SLIDESHOW } ]
		</div>

		<div id="nav">
			<span class="nav left">{ $BACK }</span>
			<span class="nav right">{ $NEXT }</span>
		</div>

		<div class="clear"></div>

		<div class="info" about="{ $IMAGEURI }">
			{ $PICTUREINFO }
			<span property="dc:created" content="{ $EXIF_DATETIMEORIGINAL }" datatype="xsd:date">{ $EXIF_DATETIMEORIGINAL }</span>
			| { $EXIF_EXPOSURETIME }s
			| { $EXIF_ISOSPEEDRATINGS }iso
			| { $EXIF_FOCALLENGTH }
			| { $EXIF_MAXAPERTUREVALUE }

			<ul class="detail">
				<li>Flash => {$EXIF_FLASH}</li>
				<li>MeteringMode => {$EXIF_METERINGMODE}</li>
				<li>Camera => {$EXIF_MAKE} {$EXIF_MODEL}</li>
				<li>WhiteBalance => {$EXIF_WHITEBALANCE}</li>
				<li>ExposureMode => {$EXIF_EXPOSUREMODE}</li>
				<li>MaxApertureValue => {$EXIF_MAXAPERTUREVALUE}</li>
				<li>FNumber => {$EXIF_FNUMBER}</li>
			</ul>
		</div>

		<div>{ $MAP }</div>
	</div>
</div>

<p id="copyleft" about="{ $IMAGEURI }">This <span href="http://purl.org/dc/dcmitype/StillImage" rel="dc:type">work</span> by <span property="cc:attributionName">Matthew Blissett</span> is licensed under a <a rel="license" href="http://creativecommons.org/licenses/by-sa/3.0/deed.en_GB">Creative Commons Attribution-ShareAlike 3.0 Unported License</a>.<br />Permissions beyond the scope of this license may be available at <a href="/contact/" rel="cc:morePermissions">http://matt.blissett.me.uk/contact/</a>.</p>
