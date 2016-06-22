<div id="page">
  <div id="menu">
{ $MENU }
  </div>
  <div>
    <table>
      <tr>
        <td colspan="3" id="picture">
          <center class="nav">
            Viewing picture (video) { $NUMBER } of { $TOTAL }<br>
            <video controls poster="{ $POSTER }">
              { $SRCS }
              <p>Your browser doesn't support playing this video file directly. You could try <a href="{ $SRC }">downloading it</a>.</p>
              <a href="{ $SRC }"><img src="{ $POSTER }" alt="Video thumbnail"></a>
            </video><br>
            Slideshow [ { $SLIDESHOW } ]
          </center>
        </td>
      </tr>
      <tr>
        <td align="left" width="20%">{ $BACK }</td>
        { $PICTUREINFO }
        <td align="right" width="20%">{ $NEXT }</td>
      </tr>
	  <tr>
	  	<td colspan="3">
		  <div id="gallery">
		    Indexed by <a href="http://apachegallery.dk">Apache::Gallery</a> - Copyright &copy; 2001-2005 Michael Legart - <a href="http://www.hestdesign.com/">Hest Design!</a>
		  </div>
		</td>
	  </tr>
    </table>
  </div>
</div>
